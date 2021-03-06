require 'builder'
require 'digest/md5'
require 'nokogiri'
require 'socket'
require 'time'
require 'xmlresolution/exceptions'
require 'xmlresolution/schema_catalog'
require 'xmlresolution/utils'
require 'xmlresolution/xml_processors'
require 'uri'
require 'rexml/document'


module XmlResolution

  # Initial Author: Randy Fischer (rf@ufl.edu) for DAITSS
  # 
  # This class analyzes an XML document, attempting to recursively
  # retrieve all of the schema documents required to correctly validate
  # it. It will optionally use an HTTP caching proxy such as squid to
  # fetch the schemas.  A list of namespaces that were not able to be
  # resolved can be retrieved using the unresolved_namespaces method.
  #
  # Example usage:
  #
  #  xrez = XmlResolution::XmlResolver.new(File.read("F20060215_AAAAHL.xml"), "file://mydoc.xml",
  #                                        "/var/resolver-files/", "satyagraha.sacred.net:3128")
  #   xrez.schema_dictionary.each do |rec|
  #      next unless rec.retrieval_status == :success
  #      puts "#{rec.namespace} => #{rec.location}\n"
  #   end
  #   puts "\nUnresolved: " + xrez.unresolved_namespaces.join(", ")
  #
  # which returns
  #
  #   http://www.fcla.edu/dls/md/daitss/ => http://www.fcla.edu/dls/md/daitss/daitss.xsd
  #   http://www.fcla.edu/dls/md/daitss/ => http://www.fcla.edu/dls/md/daitss/daitssAccount.xsd
  #   http://www.fcla.edu/dls/md/daitss/ => http://www.fcla.edu/dls/md/daitss/daitssAccountProject.xsd
  #    ...
  #   http://www.fcla.edu/dls/md/daitss/ => http://www.fcla.edu/dls/md/daitss/daitssWaveFile.xsd
  #   http://www.loc.gov/METS/ => http://www.loc.gov/standards/mets/mets.xsd
  #   http://www.loc.gov/mods/v3 => http://www.loc.gov/standards/mods/v3/mods-3-3.xsd
  #   http://www.w3.org/XML/1998/namespace => http://www.loc.gov/standards/mods/xml.xsd
  #   http://www.w3.org/1999/xlink => http://www.loc.gov/standards/xlink/xlink.xsd
  #   http://www.uflib.ufl.edu/digital/metadata/ufdc2/ => http://www.uflib.ufl.edu/digital/metadata/ufdc2/ufdc2.xsd
  #   http://www.w3.org/XML/1998/namespace => http://www.w3.org/2001/xml.xsd
  #   http://www.w3.org/2001/XMLSchema => http://www.w3.org/2001/XMLSchema.xsd
  #
  #   Unresolved: http://www.w3.org/1999/xlink, http://www.w3.org/2001/XMLSchema-instance
  #
  # Two notes on squid caching proxies: at least by default, redirects
  # are not cached (even 301 "moved permanently") so that there will
  # always be a request to the original host resulting in a redirect
  # that we will handle (though the URL we are directed to will usually
  # be cached) - an example is http://www.loc.gov/mods/v3/mods-3-2.xsd.
  # Secondly, there are common schemas, such as
  # http://dublincore.org/schemas/xmls/simpledc20021212.xsd, that squid
  # cannot cache since there is no Last-Modified, Etag, or
  # caching/expiration information associated with it. These kinds of
  # issues will slow you down somewhat, unless you take special pains (see
  # the refresh_pattern directive for squid)

  class XmlResolver
    
    # There exist basic namespaces that schema-processors 'just know
    # about', and they are not normally downloaded when encountered
    # (for instance, http://www.w3.org/2001/XMLSchema.xsd and
    # http://www.w3.org/2001/xml.xsd).  We, however, do currently
    # download those.
    #
    # In other cases there are no actual schemas at all -
    # schema-processors really do have to interpret them.
    #
    # For this latter case we do not want to report them as unresolved
    # namespaces. NAMESPACE_DONT_TELL is the place to list them.
    #

    NAMESPACE_DONT_TELL =  [
                            'http://www.w3.org/1999/xhtml',
                            'http://www.w3.org/2001/XMLSchema-hasFacetAndProperty',
                            'http://www.w3.org/2001/XMLSchema-instance'#
			    #'http://www.w3.org/1999/XSL/Transform',
			    #'http://www.w3.org/2001/XMLSchema'
                           ]

    # To avoid potential denial of service attacks (even if self-inflicted), limit the number
    # of schemas we are willing to process for one XML instance document.

    TOO_MANY_SCHEMAS  =  500

    private

    # A writable directory for storing retrieved schema documents.
    
    attr_reader :schemas_storage_directory
    
    # A writable directory for storing information about a collection of XML documents
    
    attr_reader :collections_storage_directory

    # The proxy to use when gathering schemas. If nil, go directly to the source.
    
    attr_reader :proxy
        
    # used_namespaces is meant to be used as a list of unique
    # namespaces that have been directly used by an XML document or
    # one of its schemas.  It is a hash where the values are
    # irrelevant; only the keys are important.
    
    attr_reader :used_namespaces
    
    public
    
    # resolution_time shows the time we began to process the XML document.
    
    attr_reader :resolution_time

    # The text of the XML document we'll resolve.
    
    attr_reader :document_text
    
    # A unique identifer for the document text. It is the MD5 hex digest of the document.
    
    attr_reader :document_identifier
    
    # The length of the document
    
    attr_reader :document_size
    
    # A file URL constructed from the original filename of the document.
    
    attr_reader :document_uri
    
    # schema_dictionary is a array of Structs that provides data about schemas.  See
    # documentation for XmlResolution::SchemaCatalog.  
    
    attr_reader :schema_dictionary
    
    # errors is an array of errors encountered in processing the docment; these are not necessarily fatal errors
    
    attr_reader :errors

    # fatals is boolean indicating that the document could not be parsed at all

    attr_reader :fatal


    # Be sure to keep the following somewhat in sync with the Sruct::Schema used in the SchemaCatalog.

    Struct.new("SchemaReloaded", :location, :namespace, :last_modified, :digest, :localpath, 
                                 :retrieval_status, :error_message, :redirected_location)

    
    # new DOCUMENT_TEXT, DOCUMENT_URI, DATA_ROOT, [ PROXY ]
    #
    # Create a new XmlResolver object. The XML document is provided
    # as the string DOCUMENT_TEXT, an externally-supplied identifier
    # as the string DOCUMENT_URI (normally a file URL).  DATA_ROOT, a
    # string, provides the path to the parent directory where schemas
    # and collections of information about the resolved DOCUMENT_TEXT
    # will be stored.  PROXY, if supplied, points to a proxy, to allow
    # a caching proxy to be used.

    def initialize document_text, document_uri, data_root, proxy = nil
      
      @document_text        = document_text
      @document_identifier  = Digest::MD5.hexdigest(document_text)
      #@document_identifier  = Digest::MD5.hexdigest(document_uri)    # github issue 14
      @document_uri         = document_uri
      @proxy                = proxy
      @document_size        = document_text.length
      
      @used_namespaces      = {}
      @schema_dictionary    = []
      @errors               = []     # only errors in the instance document
      @fatal                = false  # fatal errors.

      @schemas_storage_directory     = File.join(data_root, 'schemas')
      @collections_storage_directory = File.join(data_root, 'collections')
      
      ResolverUtils.check_directory "The schemas storage directory",     schemas_storage_directory        # raises ConfigurationError if permissions issues
      ResolverUtils.check_directory "The document collection directory", collections_storage_directory    # ditto
      
      raise InadequateDataError, "XML document #{document_uri} was empty" if document_size == 0
      begin
	      doc = REXML::Document.new(document_text) #   
      rescue	      
        raise XmlResolution::BadXmlDocument, $!.to_s + "   document uri: #{document_uri}"
      end


      process
    end

    
    # unresolved_namespaces
    #
    # Return an array of all of the namesapces that we have not been able to resolve.
    
    def unresolved_namespaces   
      (@used_namespaces.keys.sort - schema_dictionary.map{ |s| s.namespace } - NAMESPACE_DONT_TELL).sort { |a,b| a.downcase <=> b.downcase }
    end

    # premis_report
    #
    # Returns an XML report describing the outcome of resolving this document. An example document:
    #
    #   <?xml version="1.0" encoding="UTF-8"?>
    #   <premis xsi:schemaLocation="info:lc/xmlns/premis-v2 http://www.loc.gov/standards/premis/premis.xsd" 
    #           version="2.1" 
    #           xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"
    #           xmlns="info:lc/xmlns/premis-v2">
    #
    #   <object xsi:type="file">
    #     <objectIdentifier>
    #       <objectIdentifierType>URI</objectIdentifierType>
    #       <objectIdentifierValue>file://romeo-foxtrot.local/Users/fischer/WorkProjects/daitss2/xmlresolution/spike/random-xml/F20060402_AAAAAB_NORM.xml</objectIdentifierValue>
    #     </objectIdentifier>
    #     <objectCharacteristics>
    #       <compositionLevel>0</compositionLevel>
    #       <fixity>
    #         <messageDigestAlgorithm>MD5</messageDigestAlgorithm>
    #         <messageDigest>e6720c9ea7e7f2a70d8dd20b1af84020</messageDigest>
    #       </fixity>
    #       <size>29752</size>
    #       <format>
    #         <formatDesignation>
    #           <formatName>XML</formatName>
    #           <formatVersion>1.0</formatVersion>
    #         </formatDesignation>
    #         <formatRegistry>
    #           <formatRegistryName>http://www.nationalarchives.gov.uk/pronom</formatRegistryName>
    #           <formatRegistryKey>fmt/101</formatRegistryKey>
    #         </formatRegistry>
    #       </format>
    #     </objectCharacteristics>
    #     <linkingEventIdentifier>
    #       <linkingEventIdentifierType>URI</linkingEventIdentifierType>
    #       <linkingEventIdentifierValue>file://romeo-foxtrot.local/xmlresolution/events/e6720c9ea7e7f2a70d8dd20b1af84020-a23406</linkingEventIdentifierValue>
    #     </linkingEventIdentifier>
    #   </object>
    #
    #   <event>
    #     <eventIdentifier>
    #       <eventIdentifierType>URI</eventIdentifierType>
    #       <eventIdentifierValue>file://romeo-foxtrot.local/xmlresolution/events/e6720c9ea7e7f2a70d8dd20b1af84020-a23406</eventIdentifierValue>
    #     </eventIdentifier>
    #     <eventType>XML Resolution</eventType>
    #     <eventDateTime>2010-05-13T17:54:08-04:00</eventDateTime>
    #     <eventOutcomeInformation>
    #       <eventOutcome>success</eventOutcome>
    #       <eventOutcomeDetail>
    #         <eventOutcomeDetailExtension>
    #           <unresolved_namespace>http://www.w3.org/2001/XMLSchema</unresolved_namespace>
    #           <unresolved_namespace>http://www.w3.org/2001/XMLSchema-instance</unresolved_namespace>
    #           <unresolved_namespace>http://www.w3.org/XML/1998/namespace</unresolved_namespace>
    #         </eventOutcomeDetailExtension>
    #       </eventOutcomeDetail>
    #     </eventOutcomeInformation>
    #     <linkingAgentIdentifier>
    #       <linkingAgentIdentifierType>URI</linkingAgentIdentifierType>
    #       <linkingAgentIdentifierValue>info:fcla/daitss/xmlresolution/1.0.0</linkingAgentIdentifierValue>
    #     </linkingAgentIdentifier>
    #     <linkingObjectIdentifier>
    #       <linkingObjectIdentifierType>URI</linkingObjectIdentifierType>
    #       <linkingObjectIdentifierValue>file://romeo-foxtrot.local/Users/fischer/WorkProjects/daitss2/xmlresolution/spike/random-xml/F20060402_AAAAAB_NORM.xml</linkingObjectIdentifierValue>
    #     </linkingObjectIdentifier>
    #   </event>
    #
    #   <agent>
    #     <agentIdentifier>
    #       <agentIdentifierType>URI</agentIdentifierType>
    #       <agentIdentifierValue>info:fcla/daitss/xmlresolution/1.0.0</agentIdentifierValue>
    #     </agentIdentifier>
    #     <agentName>XML Resolution Service</agentName>
    #     <agentType>Web Service</agentType>
    #     <agentNote>
    #        Version 1.0.0, Git Revision 8160e74815a0b633af5f03ee3b629e335a42960f, Capistrano Release 20100517050854.
    #     </agentNote>
    #   </agent>
    # </premis>


    def premis_report

      #$KCODE == 'UTF8' or raise ConfigurationError, "Ruby $KCODE == #{$KCODE}, but it must be UTF8"
      
      successes = failures = 0
      
      schema_dictionary.each do |s|
	      # for stylesheet s.namespace= xml.stylesheet.type.text/xsl
	      # dtd namespace="DOCTYPE.rss.PUBLIC.-//Netscape Communications//DTD RSS 0.91//EN
        case s.retrieval_status
        when :failure            ;  failures  += 1
        when :success, :redirect ;  successes += 1
        end
      end

      broken_links = schema_dictionary.map { |s| s.location if s.retrieval_status == :failure }.compact
      if @fatal
        outcome = 'failure'
      elsif schema_dictionary.size == failures
        outcome = 'failure'
      elsif (successes > 0 and failures > 0)  or unresolved_namespaces.count > 0
        outcome = 'mixed'
      elsif failures > 0
        outcome = 'failure'
      else
        outcome = 'success'  # Vacuous case will be counted a success.
      end
      
      #broken_links = schema_dictionary.map { |s| s.location if s.retrieval_status == :failure }.compact
      event_id = mint_event_id
      
      #@http_status_code =  String.new   # not for premis xml
      xml = Builder::XmlMarkup.new(:indent => 2)
      
      xml.instruct!(:xml, :encoding => 'UTF-8')

      xml.premis('xmlns'              => 'info:lc/xmlns/premis-v2',
                 'xmlns:xsi'          => 'http://www.w3.org/2001/XMLSchema-instance',
                 'xsi:schemaLocation' => 'info:lc/xmlns/premis-v2 http://www.loc.gov/standards/premis/premis.xsd',
                 'version'            => '2.1') {

        # The object portion, strictly speaking, is not needed by DAITSS 2, it will be replaced.
        # However, it turns out to be useful validating the output, and may be useful in other
        # contexts.

        xml.object('xsi:type' => 'file') {
          xml.objectIdentifier {
            xml.objectIdentifierType('URI')
            xml.objectIdentifierValue(document_uri)
          }
          xml.objectCharacteristics {
            xml.compositionLevel('0')
            xml.fixity {
              xml.messageDigestAlgorithm('MD5')
              xml.messageDigest(document_identifier)
            }
            xml.size(document_size)
            xml.format {
              xml.formatDesignation {
                xml.formatName('XML')
                xml.formatVersion('1.0')
              }
              xml.formatRegistry {
                xml.formatRegistryName('http://www.nationalarchives.gov.uk/pronom')
                xml.formatRegistryKey('fmt/101')
              }
            }
          }
          xml.linkingEventIdentifier {
            xml.linkingEventIdentifierType('URI')
            xml.linkingEventIdentifierValue(event_id)
          }
        }
        @loc = ""
	@ns = ""
	@nsToType = {}
	@locToType = {}
	@schema_dictionary.map do |rr| @http_status_code=rr.error_message
	if  rr.namespace[0..6] == "DOCTYPE"
		@type = 'dtd'
	elsif rr.namespace[0..6] == "xml.sty"
		@type = "stylesheet"
	else
		@type = "schema"
	end
	@loc = rr.location
	@ns =  rr.namespace
	@nsToType[@ns] = @type
	@locToType[@loc] = @type
	end
        xml.event {
          xml.eventIdentifier {
            xml.eventIdentifierType('URI')
            xml.eventIdentifierValue(event_id)   # Typically this is only used as a placeholder
          }                                      # and will be re-written.
          xml.eventType('XML Resolution')
          xml.eventDateTime(@resolution_time.iso8601)
          xml.eventOutcomeInformation { 
            xml.eventOutcome(outcome) 
            if @fatal
		    puts "fatal error when parsing document:#{@document_uri} @document_identifier:#{@document_identifier}"
		    @errors.each{|z| puts(z)}
              xml.eventOutcomeDetail {
                xml.eventOutcomeDetailExtension {
                  broken_links.each do |ns|
			  xml.broken_link(ns,"type"=>@locToType[ns])
		  end
                  @errors.each { |err| xml.error(err) }

                  unresolved_namespaces.each { |ns| xml.unresolved_namespace(ns,"type"=>@nsToType[ns]) }
		  xml.http_status_code(@http_status_code) if @http_status_code  
                }
              }
           elsif (broken_links.count != 0)  or (unresolved_namespaces.count > 0) or (broken_links.count > 0)
	    attributes = {}
	    attributes[:type] = "unresolvable"      
              xml.eventOutcomeDetail {
                xml.eventOutcomeDetailExtension {
                  broken_links.each { |loc| xml.broken_link(loc,"type"=>@locToType[loc]) }
                  unresolved_namespaces.each do |ns|
			  xml.broken_link(ns,"type"=>"unresolvable")
		  end
                }
              }
            end
          }
          xml.linkingAgentIdentifier {
            xml.linkingAgentIdentifierType('URI')
            xml.linkingAgentIdentifierValue(XmlResolution.version.uri)
          }
          xml.linkingObjectIdentifier {
            xml.linkingObjectIdentifierType('URI')
            xml.linkingObjectIdentifierValue(document_uri)
          }
        }

        xml.agent() {
          xml.agentIdentifier {
            xml.agentIdentifierType('URI')
            xml.agentIdentifierValue(XmlResolution.version.uri)
          }
          xml.agentName('XML Resolution Service')
          xml.agentType('Web Service')
          xml.agentNote(XmlResolution.version.rev)                        
        }
      }
      xml.target!
    end

    # save COLLECTION_ID
    #
    # Serialize the data we've collected for the XML document, saving
    # the information in a format we can easily reread.  It is saved
    # in the directory named .../collections/COLLECTION_ID/; for the
    # filename of the data we use the MD5 checksum of the XML
    # document.
    
    def save collection_id

      raise XmlResolution::BadCollectionID, "Invalid collection identifier '#{collection_id}'" unless ResolverUtils.collection_name_ok? collection_id

      record_file = File.join(collections_storage_directory, collection_id, document_identifier)

      begin
        ResolverUtils.check_directory "", File.join(collections_storage_directory, collection_id)
      rescue
        raise XmlResolution::BadCollectionID, "The collection identifier '#{collection_id}' hasn't been created yet. Use PUT to create it first"
      end

      ResolverUtils.write_lock(record_file) do |fd|
        fd.write dump
      end
    end
    
    
    #
    # input:
    #         text:                    of an xml document
    #         namespace_locations:     a hash   of locations=> namesspaces
    #output:
    #         namespace_location   has extra entries for DTD and Processing Instrctions
    #
    #1. first lop off all children of the root node
    #2. then delete all comment nodes
    #3. what is left are DTDs  and Processing instructions
    #4. by text parsing determine if DTD or PI
    #
    def get_PI_DTD! (text,namespace_locations) 	    
	    # (rdb:1) e xmldoc = Nokogiri::XML(preamble)
	    #
	    # found a bug  when there is a DTD and PI dtd gets excised out
	     #(rdb:1) e  ch=xmldoc.children.each {|c| x  = "#{c}"}
	    #0
	    #(rdb:1) e x
	    #"<?xml-stylesheet type=\"text/xsl\" href=\"http://schema.fcla.edu/xml/MARC21slim2MODS3-4.xsl\"?>"
	    #
    doc = REXML::Document.new(text)  #  the include REXML avoid REXML::Document
    root = doc.root
    #root.each_child {|f|  root.delete(f) if f.instance_of? REXML::Comment}
    root_str = root.to_s
    if root.prefix.length != 0
       preamble_index =  text.index('<'+root.prefix+':'+root.name) - 1
    else
	    preamble_index =  text.index('<'+root.name) - 1
    end   
    preamble  = text[0..preamble_index]
    comment_begin = preamble.index('<!--')
    while comment_begin
	    comment_end = preamble.index('-->',comment_begin)
	    if comment_end  == nil
		    break
	    else
		    preamble = preamble[0..comment_begin-1] + preamble[comment_end+3,preamble.length]
		    comment_begin = preamble.index('<!--')
	    end

    end
    xmldoc = Nokogiri::XML(preamble)
    dtd_pi_ar = Array.new
    xmldoc.children.each do |c|
	x  = "#{c}"
	dtd_pi_ar.push(x)

     end

    location = String.new
    dtd_pi_ar.collect! do |f|
	if (f.index('<!DOCTYPE') != nil || f.index('<?') != nil )  && f.index('http://') == nil  # this implies a local or not DTD and not PI
		next    
	end
	words = f.scan(/(?:"")|(?:"(.*[^\\])")|(\w+)/).flatten.compact
	namespace = ""             #  words[0]
	words.each do |w|
		if w.include?('http://')
			location = w[w.index('http://')..w.length-1]
			namespace = namespace + w[0..w.index('http://') - 1] + '.'
	        else
			namespace =  namespace + w + '.'
        	end
	end
	if namespace.end_with?('href=".')                     # style sheet 
		namespace = namespace[0...namespace.length - 9]
	elsif namespace.end_with?('" ".')                     # PUBLIC DTD
	        namespace=namespace[0..namespace.size-5]
	elsif namespace.end_with?('.')                     # other DTD          
		namespace=namespace[0...namespace.size-1]
	end
	namespace_locations[location] = namespace
    end

    
    end
    
    
    
    
    
    
    private

    # process
    #
    # Process the XML instance document, downloading the schemas it references, analyze the schemas, and 
    # download the schemas *those* reference, and so on, until we're done.
    
    def process
      @resolution_time = Time.now
      
      instance_document   = analyze_xml_document(document_text)
      namespace_locations = instance_document.namespace_locations   # a hash of Location-URL => Namespace-URN pairs
      @used_namespaces    = instance_document.used_namespaces       # a hash of Namespace-URN => 'true' pairs 

      @errors = instance_document.errors

      if (instance_document.errors.count > 0) and namespace_locations.empty? and @used_namespaces.empty?
        @fatal = true
        return
      end
      get_PI_DTD!( document_text,namespace_locations)
      catalog = SchemaCatalog.new(namespace_locations, schemas_storage_directory, proxy)

      count = 0
      catalog.schemas do |schema_record|
        count += 1

        next if schema_record.retrieval_status != :success
        schema_document = analyze_schema_document(schema_record.location, File.read(schema_record.localpath), @used_namespaces)
        catalog.merge schema_document.namespace_locations

        raise XmlResolution::TooManyDarnSchemas,  "Too many schemas (#{count}) encountered for #{document_uri}." if count > TOO_MANY_SCHEMAS
      end
      
      @schema_dictionary = catalog.schemas   # only those actually required, that is, in used_namespaces
    end


    def mint_event_id
      'file://' + Socket::gethostname  + File::SEPARATOR + File.join('xmlresolution', 'events', document_identifier + '-' + Digest::MD5.hexdigest(rand(1_000_000_000_000).to_s)[0..5])
    end

    def analyze_xml_document text
      document = PlainXmlDocument.new
      Nokogiri::XML::SAX::Parser.new(document).parse(text)
      return document
    end
    
    def analyze_schema_document schema_location, schema_text, namespaces
      document = SchemaDocument.new(schema_location, namespaces)
      Nokogiri::XML::SAX::Parser.new(document).parse(schema_text)
      return document
    end

    # dump
    #
    # Return a string representation of our analysis of an xml document, along the lines of:
    #
    #  FILE_NAME url
    #  DIGEST md5
    #  SIZE fixnum
    #  DATE_TIME time
    #  SCHEMA md5 modification location namespace
    #  SCHEMA md5 modification location namespace
    #  SCHEMA md5 modification location namespace
    #  SCHEMA md5 modification location namespace
    #   ....
    #  BROKEN_SCHEMA location namespace error_message
    #  BROKEN_SCHEMA location namespace error_message
    #   ....
    #  REDIRECTED_SCHEMA location namespace redirected_locaton
    #  REDIRECTED_SCHEMA location namespace redirected_locaton
    #   ...
    #  ERROR message
    #  ERROR message
    #  ....
    #  UNRESOLVED_NAMESPACES namespace namespace namespace ....
    #
    # Each 'phrase' is URL-escaped, so embeded whitespace won't cause parsing problems.

    def dump
      str = ''
      str += ResolverUtils.escape("FILE_NAME", document_uri)            + "\n"
      str += ResolverUtils.escape("DATE_TIME", resolution_time.iso8601) + "\n"
      str += ResolverUtils.escape("DIGEST",    document_identifier)     + "\n"
      str += ResolverUtils.escape("LENGTH",    document_size.to_s)      + "\n"

      schema_dictionary.each do |s|
        next unless s.retrieval_status == :success
        str += ResolverUtils.escape("SCHEMA", s.digest, s.last_modified.iso8601, s.location, s.namespace)   + "\n"
      end

      schema_dictionary.each do |s|
        next unless s.retrieval_status == :failure
        str += ResolverUtils.escape("BROKEN_SCHEMA", s.location, s.namespace, s.error_message) + "\n"
      end

      schema_dictionary.each do |s|
        next unless s.retrieval_status == :redirect
        str += ResolverUtils.escape("REDIRECTED_SCHEMA", s.location, s.namespace, s.redirected_location) + "\n"
      end

      errors.each do |mess|
        str += ResolverUtils.escape("ERROR", mess) + "\n"
      end

      str += ResolverUtils.escape("UNRESOLVED_NAMESPACES", *unresolved_namespaces) + "\n"
    end # of def
  end # of class XmlResolver


  # XmlResolverReloaded provides a subset of the capabilities of the XmlResolver class; it
  # reloads the data that is dumped via XmlResolver#dump.  In particular, we can get:
  #
  #  * those successfully retrieved schemas needed for understanding the analyzed document
  #  * a list of unretrievable and redirected schemas 
  #  * the unresolved namespaces
  #  * basic information about the document analyzed: checksum, size, original filename.
  #
  # The original document text is no longer available, however.

  class XmlResolverReloaded < XmlResolver

    def initialize data_root, collection_id, document_identifier

      @document_text       = nil
      @proxy               = nil
      @document_size       = nil
      @collection_id       = collection_id
      
      @used_namespaces     = {}
      @schema_dictionary   = []
      @errors              = []
      @schemas_storage_directory     = File.join(data_root, 'schemas')
      @collections_storage_directory = File.join(data_root, 'collections')

      ResolverUtils.check_directory "The schemas storage directory",     schemas_storage_directory  # raise ConfigurationError if issue
      ResolverUtils.check_directory "The document collection directory", collections_storage_directory
      
      # Load up @resolution_time, @document_identifier, @document_uri, @schema_dictionary, @used_namespaces:
      
      filename = File.join(@collections_storage_directory, @collection_id, document_identifier)
      
      if not File.exists? filename
        raise ConfigurationError, "Can't find the data file #{document_identifier} for the collection #{collection_id} to read in schema info (looking in #{@collections_storage_directory})"
      end

      if not File.readable? filename
        raise ConfigurationError, "Can't read the data file #{document_identifier} for the collection #{collection_id} to read in schema info (looking in #{@collections_storage_directory})"
      end
      load File.read filename
    end

    private

    # load TEXT
    #
    # Given the data that dump produces, read it in and recreate most of objects that dump dumps.
    # See the parent's XmlResolver.dump method for the details

    def load text

      unresolved = []

      text.split("\n").each do |line|
        data = ResolverUtils.unescape line

        case data.shift

        when 'DATE_TIME'             then @resolution_time       = Time.parse data.shift
        when 'DIGEST'                then @document_identifier   = data.shift
        when 'FILE_NAME'             then @document_uri          = data.shift
        when 'LENGTH'                then @document_size         = data.shift.to_i
        when 'UNRESOLVED_NAMESPACES' then unresolved = data
        when 'ERROR'                 then @errors.push data

        when 'SCHEMA'
          s = Struct::SchemaReloaded.new

          s.digest           = data.shift
          s.last_modified    = Time.parse(data.shift)
          s.location         = data.shift
          s.namespace        = data.shift
          s.retrieval_status = :success
          s.localpath        = File.join(@schemas_storage_directory, Digest::MD5.hexdigest(s.digest+s.location)) # github issue #14

          @schema_dictionary.push s

        when 'BROKEN_SCHEMA'                   # misnomer: usually they are simply unretrievable, not broken.
          s = Struct::SchemaReloaded.new

          s.location         = data.shift
          s.namespace        = data.shift
          s.error_message    = data.shift
          s.retrieval_status = :failure

          @schema_dictionary.push s

        when 'REDIRECTED_SCHEMA'
          s = Struct::SchemaReloaded.new

          s.location            = data.shift
          s.namespace           = data.shift
          s.redirected_location = data.shift
          s.retrieval_status    = :redirect

          @schema_dictionary.push s

        end # of case
      end # of split loop

      # record all the namespaces we've re-read as of interest.

      unresolved.each { |ns| @used_namespaces[ns] = true }
      @schema_dictionary.each { |s| @used_namespaces[s.namespace] = true }

    end # of def
  end # of class
end # of module
