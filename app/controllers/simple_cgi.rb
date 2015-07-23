#
# ruby training
#

class SimpleCGI
  $CGI_ENV = ENV    # for FCGI support

  # String for carriage return
  CR  = "\015"

  # String for linefeed
  LF  = "\012"

  # Standard internet newline sequence
  EOL = CR + LF

  # Synonym for ENV.
  def env_table
    ENV
  end

  # Synonym for $stdin.
  def stdinput
    $stdin
  end

  # Synonym for $stdout.
  def stdoutput
    $stdout
  end

  private :env_table, :stdinput, :stdoutput


  # Parse an HTTP query string into a hash of key=>value pairs.
  #
  #   params = CGI::parse("query_string")
  #     # {"name1" => ["value1", "value2", ...],
  #     #  "name2" => ["value1", "value2", ...], ... }
  #
  def SimpleCGI::parse(query)
    params = {}
    query.split(/[&;]/).each do |pairs|
      key, value = pairs.split('=',2).collect{|v| SimpleCGI::unescape(v) }
      if key && value
        params.has_key?(key) ? params[key].push(value) : params[key] = [value]
      elsif key
        params[key]=[]
      end
    end
    params
  end

  # Maximum content length of post data
  ##MAX_CONTENT_LENGTH  = 2 * 1024 * 1024

  # Maximum content length of multipart data
  MAX_MULTIPART_LENGTH  = 128 * 1024 * 1024

  # Maximum number of request parameters when multipart
  MAX_MULTIPART_COUNT = 128


  # Mixin module that provides the following:
  #
  # 1. Access to the CGI environment variables as methods.  See
  #    documentation to the CGI class for a list of these variables.  The
  #    methods are exposed by removing the leading +HTTP_+ (if it exists) and
  #    downcasing the name.  For example, +auth_type+ will return the
  #    environment variable +AUTH_TYPE+, and +accept+ will return the value
  #    for +HTTP_ACCEPT+.
  #
  # 2. Access to cookies, including the cookies attribute.
  #
  # 3. Access to parameters, including the params attribute, and overloading
  #    #[] to perform parameter value lookup by key.
  #
  # 4. The initialize_query method, for initializing the above
  #    mechanisms, handling multipart forms, and allowing the
  #    class to be used in "offline" mode.
  #
  module QueryExtension

    # offline mode. read the parameters as a query
    attr_accessor :offline_parames

    # Get the parameters as a hash of name=>values pairs, where
    # values is an Array.
    attr_reader :params

    # Get the uploaded files as a hash of name=>values pairs
    attr_reader :files

    # Set all the parameters.
    def params=(hash)
      @params.clear
      @params.update(hash)
    end

    ##
    # Parses multipart form elements according to 
    #   http://www.w3.org/TR/html401/interact/forms.html#h-17.13.4.2
    #
    # Returns a hash of multipart form parameters with bodies of type StringIO or 
    # Tempfile depending on whether the multipart form element exceeds 10 KB
    #
    #   params[name => body]
    #
    def read_multipart(boundary, content_length)
      ## read first boundary
      stdin = stdinput
      first_line = "--#{boundary}#{EOL}"
      content_length -= first_line.bytesize
      status = stdin.read(first_line.bytesize)
      raise EOFError.new("no content body")  unless status
      raise EOFError.new("bad content body") unless first_line == status

      ## parse and set params
      params = {}
      @files = {}
      boundary_rexp = /--#{Regexp.quote(boundary)}(#{EOL}|--)/
      boundary_size = "#{EOL}--#{boundary}#{EOL}".bytesize
      boundary_end  = nil
      buf = ''
      bufsize = 10 * 1024
      max_count = MAX_MULTIPART_COUNT
      n = 0
      tempfiles = []

      while true
        #(n += 1) < max_count or raise StandardError.new("too many parameters.")

        ## create body (StringIO or Tempfile)
        body = create_body()
        #tempfiles << body if defined?(Tempfile) && body.kind_of?(Tempfile)
        tempfiles << body
        class << body
          if method_defined?(:path)
            alias local_path path
          else
            def local_path
              nil
            end
          end
          attr_reader :original_filename, :content_type
        end
        ## find head and boundary
        head = nil
        separator = EOL * 2
        until head && matched = boundary_rexp.match(buf)
          if !head && pos = buf.index(separator)
            len  = pos + EOL.bytesize
            head = buf[0, len]
            buf  = buf[(pos+separator.bytesize)..-1]
          else
            if head && buf.size > boundary_size
              len = buf.size - boundary_size
              body.print(buf[0, len])
              buf[0, len] = ''
            end
            c = stdin.read(bufsize < content_length ? bufsize : content_length)
            raise EOFError.new("bad content body") if c.nil? || c.empty?
            buf << c
            content_length -= c.bytesize
          end
        end
        ## read to end of boundary
        m = matched
        len = m.begin(0)
        s = buf[0, len]
        if s =~ /(\r?\n)\z/
          s = buf[0, len - $1.bytesize]
        end
        body.print(s)
        buf = buf[m.end(0)..-1]
        boundary_end = m[1]
        content_length = -1 if boundary_end == '--'
        ## reset file cursor position
        #body.rewind
        body.seek(0, IO::SEEK_SET)
        
        ## original filename
        /Content-Disposition:.* filename=(?:"(.*?)"|([^;\r\n]*))/i.match(head)
        filename = $1 || $2 || ''
        filename = SimpleCGI.unescape(filename)# if unescape_filename?()
        body.instance_variable_set('@original_filename', filename)
        ## content type
        /Content-Type: (.*)/i.match(head)
        (content_type = $1 || '').chomp!
        body.instance_variable_set('@content_type', content_type)
        ## query parameter name
        /Content-Disposition:.* name=(?:"(.*?)"|([^;\r\n]*))/i.match(head)
        name = $1 || $2 || ''
        if body.original_filename == ""
          #value=body.read.dup.force_encoding(@accept_charset)
          value=body.read.dup
          (params[name] ||= []) << value
          unless value.valid_encoding?
            if @accept_charset_error_block
              @accept_charset_error_block.call(name,value)
            else
              raise InvalidEncoding,"Accept-Charset encoding error"
            end
          end
          class << params[name].last;self;end.class_eval do
            define_method(:read){self}
            define_method(:original_filename){""}
            define_method(:content_type){""}
          end
        else
          (params[name] ||= []) << body
          @files[name]=body
        end
        ## break loop
        break if content_length == -1
      end

      #... raise EOFError, "bad boundary end of body part" unless boundary_end =~ /--/
      params.default = []
      params
    rescue => e
      p e.class
      p e.message
      p e.backtrace
      #if tempfiles
      #  tempfiles.each {|t|
      #    if t.path
      #      t.unlink
      #    end
      #  }
      #end
      #raise
    end # read_multipart
    
    def create_body()  #:nodoc:
      #require 'tempfile'
      body = Tempfile.new('CGI')
      return body
    end
    #def create_body(is_large)  #:nodoc:
    #  if is_large
    #    require 'tempfile'
    #    body = Tempfile.new('CGI', encoding: "ascii-8bit")
    #  else
    #    begin
    #      require 'stringio'
    #      body = StringIO.new("".force_encoding("ascii-8bit"))
    #    rescue LoadError
    #      require 'tempfile'
    #      body = Tempfile.new('CGI', encoding: "ascii-8bit")
    #    end
    #  end
    #  body.binmode if defined? body.binmode
    #  return body
    #end
    def unescape_filename?  #:nodoc:
      user_agent = $CGI_ENV['HTTP_USER_AGENT']
      return /Mac/i.match(user_agent) && /Mozilla/i.match(user_agent) && !/MSIE/i.match(user_agent)
    end

    # A wrapper class to use a StringIO object as the body and switch
    # to a TempFile when the passed threshold is passed.
    # Initialize the data from the query.
    #
    # Handles multipart forms (in particular, forms that involve file uploads).
    # Reads query parameters in the @params field, and cookies into @cookies.
    def initialize_query()
      if ("POST" == env_table['REQUEST_METHOD']) and
         %r|\Amultipart/form-data.*boundary=\"?([^\";,]+)\"?|.match(env_table['CONTENT_TYPE'])
        raise StandardError.new("too large multipart data.") if env_table['CONTENT_LENGTH'].to_i > MAX_MULTIPART_LENGTH
        boundary = $1.dup
        @multipart = true
        @params = read_multipart(boundary, env_table['CONTENT_LENGTH'].to_i)
        #@params = "none support multipart"
      else
        @multipart = false
        @params = SimpleCGI::parse(
                    case env_table['REQUEST_METHOD']
                    when "GET", "HEAD"
                      env_table['QUERY_STRING'] or ""
                    when "POST"
                      stdinput.read(env_table['CONTENT_LENGTH'].to_i) or ''
                    else
                      @offline_parames
                    end.dup
                  )
        #... Encoding
        #unless Encoding.find(@accept_charset) == Encoding::ASCII_8BIT
        #  @params.each do |key,values|
        #    values.each do |value|
        #      unless value.valid_encoding?
        #        if @accept_charset_error_block
        #          @accept_charset_error_block.call(key,value)
        #        else
        #          raise InvalidEncoding,"Accept-Charset encoding error"
        #        end
        #      end
        #    end
        #  end
        #end
      end

    end
    #private :initialize_query

    # Returns whether the form contained multipart/form-data
    def multipart?
      @multipart
    end

    # Get the value for the parameter with a given key.
    #
    # If the parameter has multiple values, only the first will be
    # retrieved; use #params to get the array of values.
    def [](key)
      params = @params[key]
      return '' unless params
      value = params[0]
      #if @multipart
      #  if value
      #    return value
      #  elsif defined? StringIO
      #    StringIO.new("".force_encoding("ascii-8bit"))
      #  else
      #    Tempfile.new("CGI",encoding:"ascii-8bit")
      #  end
      #else
      #  str = if value then value.dup else "" end
      #  str
      #end
    end

    # Return all query parameter names as an array of String.
    def keys(*args)
      @params.keys(*args)
    end

    # Returns true if a given query string parameter exists.
    def has_key?(*args)
      @params.has_key?(*args)
    end
    alias key? has_key?
    alias include? has_key?

  end # QueryExtension

















  # Exception raised when there is an invalid encoding detected
  class InvalidEncoding < Exception; end

  # @@accept_charset is default accept character set.
  # This default value default is "UTF-8"
  # If you want to change the default accept character set
  # when create a new CGI instance, set this:
  #
  #   CGI.accept_charset = "EUC-JP"
  #
  @@accept_charset="UTF-8"

  # Return the accept character set for all new CGI instances.
  def self.accept_charset
    @@accept_charset
  end

  # Set the accept character set for all new CGI instances.
  def self.accept_charset=(accept_charset)
    @@accept_charset=accept_charset
  end

  # Return the accept character set for this CGI instance.
  attr_reader :accept_charset











  # Create a new CGI instance.
  #
  # :call-seq:
  #   CGI.new(tag_maker) { block }
  #   CGI.new(options_hash = {}) { block }
  #
  #
  # <tt>tag_maker</tt>::
  #   This is the same as using the +options_hash+ form with the value <tt>{
  #   :tag_maker => tag_maker }</tt> Note that it is recommended to use the
  #   +options_hash+ form, since it also allows you specify the charset you
  #   will accept.
  # <tt>options_hash</tt>::
  #   A Hash that recognizes two options:
  #
  #   <tt>:accept_charset</tt>::
  #     specifies encoding of received query string.  If omitted,
  #     <tt>@@accept_charset</tt> is used.  If the encoding is not valid, a
  #     CGI::InvalidEncoding will be raised.
  #
  #     Example. Suppose <tt>@@accept_charset</tt> is "UTF-8"
  #
  #     when not specified:
  #
  #         cgi=CGI.new      # @accept_charset # => "UTF-8"
  #
  #     when specified as "EUC-JP":
  #
  #         cgi=CGI.new(:accept_charset => "EUC-JP") # => "EUC-JP"
  #
  #   <tt>:tag_maker</tt>::
  #     String that specifies which version of the HTML generation methods to
  #     use.  If not specified, no HTML generation methods will be loaded.
  #
  #     The following values are supported:
  #
  #     "html3":: HTML 3.x
  #     "html4":: HTML 4.0
  #     "html4Tr":: HTML 4.0 Transitional
  #     "html4Fr":: HTML 4.0 with Framesets
  #
  # <tt>block</tt>::
  #   If provided, the block is called when an invalid encoding is
  #   encountered. For example:
  #
  #     encoding_errors={}
  #     cgi=CGI.new(:accept_charset=>"EUC-JP") do |name,value|
  #       encoding_errors[name] = value
  #     end
  #
  # Finally, if the CGI object is not created in a standard CGI call
  # environment (that is, it can't locate REQUEST_METHOD in its environment),
  # then it will run in "offline" mode.  In this mode, it reads its parameters
  # from the command line or (failing that) from standard input.  Otherwise,
  # cookies and other parameters are parsed automatically from the standard
  # CGI locations, which varies according to the REQUEST_METHOD.
  def initialize(options = {}, &block) # :yields: name, value
    #@accept_charset_error_block=block if block_given?
    #@options={:accept_charset=>@@accept_charset}
    # enable!
    #case options
    #when Hash
    #  @options.merge!(options)
    #when String
    #  @options[:tag_maker]=options
    #end
    #@accept_charset=@options[:accept_charset]
    #if defined?(MOD_RUBY) && !ENV.key?("GATEWAY_INTERFACE")
    #  Apache.request.setup_cgi_env
    #end

    extend QueryExtension
    @multipart = false

    @offline_parames = "offline=true"

    initialize_query()  # set @params, @cookies
    #@output_cookies = nil
    #@output_hidden = nil

    #case @options[:tag_maker]
    #when "html3"
    #  require 'cgi/html'
    #  extend Html3
    #  element_init()
    #  extend HtmlExtension
    #when "html4"
    #  require 'cgi/html'
    #  extend Html4
    #  element_init()
    #  extend HtmlExtension
    #when "html4Tr"
    #  require 'cgi/html'
    #  extend Html4Tr
    #  element_init()
    #  extend HtmlExtension
    #when "html4Fr"
    #  require 'cgi/html'
    #  extend Html4Tr
    #  element_init()
    #  extend Html4Fr
    #  element_init()
    #  extend HtmlExtension
    #end
  end

end

class SimpleCGI
  
  #@@accept_charset="UTF-8" unless defined?(@@accept_charset) # ...mruby none supported
  @@accept_charset="UTF-8"

  # URL-encode a string.
  #   url_encoded_string = CGI::escape("'Stop!' said Fred")
  #      # => "%27Stop%21%27+said+Fred"
  def SimpleCGI::escape(string)
        string.gsub(/([^ a-zA-Z0-9_.-]+)/) do
          '%' + $1.unpack('H2' * $1.bytesize).join('%').upcase
        end.gsub(/ /m, "+")
        #end.tr(' ', '+') # ...mruby none supported
  end

  # URL-decode a string with encoding(optional).
  #   string = CGI::unescape("%27Stop%21%27+said+Fred")
  #      # => "'Stop!' said Fred"
  def SimpleCGI::unescape(string,encoding=@@accept_charset)
    str=string.gsub(/\+/m, " ").gsub(/((?:%[0-9a-fA-F]{2})+)/) do
      #[$1.delete('%')].pack('H*') # ...mruby none supported
      [$1.gsub(/%/m, "")].pack('H*')
    end
  end
  #def SimpleCGI::unescape(string,encoding=@@accept_charset)
  #  str=string.gsub(/\+/m, " ").force_encoding(Encoding::ASCII_8BIT).gsub(/((?:%[0-9a-fA-F]{2})+)/) do
  #    [$1.delete('%')].pack('H*')
  #  end.force_encoding(encoding)
  #  str.valid_encoding? ? str : str.force_encoding(string.encoding)
  #end

end  # class SimpleCGI 


if __FILE__ == $0
 ENV['REQUEST_METHOD'] = "GET"
 ENV['REQUEST_METHOD'] = "POST"
 ENV['CONTENT_LENGTH'] = "417"
 ENV['CONTENT_TYPE'] = "multipart/form-data; boundary=AaB03x"
 ENV['QUERY_STRING'] = "hoge=1"

 %r|\Amultipart/form-data.*boundary=\"?([^\";,]+)\"?|.match("multipart/form-data; boundary=AaB03x")
 p $1

 cgi = SimpleCGI.new 
 p cgi.params
#
#--AaB03x
#Content-Disposition: form-data; name="submit-name"
#
#Larry
#--AaB03x
#Content-Disposition: form-data; name="file01"; filename="file1.txt"
#Content-Type: text/plain
#
#... contents of file1.txt ... 
#
#... end
#
#--AaB03x
#Content-Disposition: form-data; name="file02"; filename="file2.txt"
#Content-Type: text/plain
#
#... contents of file2.txt ... 
#
#... end
#
#--AaB03x--
end
