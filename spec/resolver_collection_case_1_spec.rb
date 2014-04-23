# encoding: UTF-8
warn_level = $VERBOSE
$VERBOSE = nil 
require 'xmlresolution/resolver_collection'
require 'xmlresolution/xml_resolver'
require 'socket'
require 'tempfile'

@@locations = Array.new
@@manifest = Object.new
@@xmlcases_resolver = Object.new

include XmlResolution
describe ResolverCollection do
  @@store = nil
  @@files = File.join(File.dirname(__FILE__), 'files', 'example-xml-documents')
  def proxy 
    prox = ENV['RESOLVER_PROXY']
    prox ||= case hostname
             when /romeo-foxtrot/;   'localhost:3128'
             when /sacred.net/;      'satyagraha.sacred.net:3128'
             when /fcla.edu/;        'sake.fcla.edu'
             else
               nil
             end
    
    if prox.nil? and not @@enough_already
      @@enough_already = true
      STDERR.puts 'No http proxy set: will download schemas directly - very slow.  Set environment variable RESOLVER_PROXY to caching proxy if you want to speed this up.'
    end
    prox
  end
  
  def what_should_get_resolved
    ['http://schema.fcla.edu/xml/student_html.xsl']
  end


  def hostname 
    Socket.gethostname
  end

  def file_url name
    "file://#{hostname}/" + name.gsub(%r{^/+}, '')
  end




  def xmlcases_instance_doc
    File.join(@@files, 'redir-rss-system.xml')
  end


  def collection_name_1
    'E20100524_ZODIAC'
  end


  before(:all) do 
    @@store = Dir.mktmpdir('resolver-store-', '/tmp')
    FileUtils.mkdir_p File.join(@@store, 'schemas')
    FileUtils.mkdir_p File.join(@@store, 'collections')
  end

  after(:all) do
    FileUtils::rm_rf @@store
  end

  it "should create new collections" do
    ResolverCollection.new(@@store, collection_name_1)

    ResolverCollection.collections(@@store).include?(collection_name_1).should == true
  end

  it "should save document resolution data" do

    # resolve three representative documents:
    @@xmlcases_resolver   = XmlResolver.new(File.read(xmlcases_instance_doc),   file_url(xmlcases_instance_doc),   @@store, proxy)

    # save the data collected to our collection

    @@xmlcases_resolver.save(collection_name_1)

    # Let's get the collection:

    collection = ResolverCollection.new(@@store, collection_name_1)

    # look through the resolutions in the collection: grab the document identifiers in doc_ids

    doc_ids = collection.resolutions.map { |resolver| resolver.document_identifier }

    # do we have all three we expect? (check for the document identifiers we've saved)

    collection.resolutions.count.should == 1
    doc_ids.include?(@@xmlcases_resolver.document_identifier).should   == true
  end



   it "should be a success eventOutcome " do
         premis_report =  @@xmlcases_resolver.premis_report
         premis_report.index('<eventOutcome>success</eventOutcome>').should_not be_nil
   end

  it "should give the collapsed list of schemas" do
    # get the collection of resolutions we've created:
    collection = ResolverCollection.new(@@store, collection_name_1)

    collection.resolutions.count.should == 1

    # Create a uniquified list of all of the downloaded schemas... we
    # expect around 16 of them (lots of repeated schemas over the
    # four  document resolutions):

    schema_locs = {}
    collection.resolutions.each do |resolver|
      list = resolver.schema_dictionary.map{ |rec| rec.location if rec.retrieval_status == :success  }.compact
      list.each { |loc| schema_locs[loc] = true }
    end
    @@locations = schema_locs.keys.sort { |a,b| a.downcase <=> b.downcase }
    # as 20120712  the exact number was 16
    @@locations.count.should == 1  # 70
    
    # Make sure all the successfully downloaded schemas in the resolution objects are listed somewhere in the manifest:

    @@manifest = collection.manifest

    @@locations.each { |loc|  /#{loc}/.should =~ @@manifest }

    # Create a tarfile of the schemas; get a table of contents of the tar'd output of the collection using a third-party
    # tar program:
    
    tmp = Tempfile.new('tar-', '/tmp')
    collection.tar do |io|
      tmp.write io.read
    end
    tmp.close
    tar_toc = `tar tvf #{tmp.path}`
    tmp.unlink

    # Do we have a manifest in the tar file?

    %r{#{collection.collection_name}/manifest\.xml}.should =~ tar_toc

    # Is each of the locations we found represented in the tar file?

    @@locations.each do |loc| 
      tar_entry = "#{collection.collection_name}/#{loc}".sub('http://', 'http/')
      %r{#{tar_entry}}.should =~ tar_toc
    end


  end

  it "should resolve these" do
    what_should_get_resolved.each{|z| @@locations.include?(z).should}
  end

end # ResolverCollection




