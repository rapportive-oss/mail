require 'mail/fields'

# encoding: utf-8
module Mail
  # Provides a single class to call to create a new structured or unstructured
  # field.  Works out per RFC what field of field it is being given and returns
  # the correct field of class back on new.
  #
  # ===Per RFC 2822
  #
  #  2.2. Header Fields
  #
  #     Header fields are lines composed of a field name, followed by a colon
  #     (":"), followed by a field body, and terminated by CRLF.  A field
  #     name MUST be composed of printable US-ASCII characters (i.e.,
  #     characters that have values between 33 and 126, inclusive), except
  #     colon.  A field body may be composed of any US-ASCII characters,
  #     except for CR and LF.  However, a field body may contain CRLF when
  #     used in header "folding" and  "unfolding" as described in section
  #     2.2.3.  All field bodies MUST conform to the syntax described in
  #     sections 3 and 4 of this standard.
  #
  class Field

    include Utilities
    include Comparable

    STRUCTURED_FIELDS = %w[ bcc cc content-description content-disposition
                            content-id content-location content-transfer-encoding
                            content-type date from in-reply-to keywords message-id
                            mime-version received references reply-to
                            resent-bcc resent-cc resent-date resent-from
                            resent-message-id resent-sender resent-to
                            return-path sender to ]

    KNOWN_FIELDS = STRUCTURED_FIELDS + ['comments', 'subject']

    FIELDS_MAP = {
      "to" => ToField,
      "cc" => CcField,
      "bcc" => BccField,
      "message-id" => MessageIdField,
      "in-reply-to" => InReplyToField,
      "references" => ReferencesField,
      "subject" => SubjectField,
      "comments" => CommentsField,
      "keywords" => KeywordsField,
      "date" => DateField,
      "from" => FromField,
      "sender" => SenderField,
      "reply-to" => ReplyToField,
      "resent-date" => ResentDateField,
      "resent-from" => ResentFromField,
      "resent-sender" =>  ResentSenderField,
      "resent-to" => ResentToField,
      "resent-cc" => ResentCcField,
      "resent-bcc" => ResentBccField,
      "resent-message-id" => ResentMessageIdField,
      "return-path" => ReturnPathField,
      "received" => ReceivedField,
      "mime-version" => MimeVersionField,
      "content-transfer-encoding" => ContentTransferEncodingField,
      "content-description" => ContentDescriptionField,
      "content-disposition" => ContentDispositionField,
      "content-type" => ContentTypeField,
      "content-id" => ContentIdField,
      "content-location" => ContentLocationField,
    }

    FIELD_NAME_MAP = FIELDS_MAP.inject({}) do |map, (field, field_klass)|
      map.update(field => field_klass::CAPITALIZED_FIELD)
    end

    # Generic Field Exception
    class FieldError < StandardError
    end

    # Raised when a parsing error has occurred (ie, a StructuredField has tried
    # to parse a field that is invalid or improperly written)
    class ParseError < FieldError #:nodoc:
      attr_accessor :element, :value, :reason

      def initialize(element, value, reason)
        @element = element
        @value = value
        @reason = reason
        super("#{element} can not parse |#{value}|\nReason was: #{reason}")
      end
    end

    # Raised when attempting to set a structured field's contents to an invalid syntax
    class SyntaxError < FieldError #:nodoc:
    end

    # Accepts a string:
    #
    #  Field.new("field-name: field data")
    #
    # Or name, value pair:
    #
    #  Field.new("field-name", "value")
    #
    # Or a name by itself:
    #
    #  Field.new("field-name")
    #
    # Note, does not want a terminating carriage return.  Returns
    # self appropriately parsed.  If value is not a string, then
    # it will be passed through as is, for example, content-type
    # field can accept an array with the type and a hash of
    # parameters:
    #
    #  Field.new('content-type', ['text', 'plain', {:charset => 'UTF-8'}])
    def initialize(name, value = nil, charset = 'utf-8')
      case
      when name =~ /:/                  # Field.new("field-name: field data")
        @name = name[FIELD_PREFIX]
        @raw_source = name
        @charset = value.blank? ? charset : value
      when name !~ /:/ && value.blank?  # Field.new("field-name")
        @name = name
        @value = nil
        @charset = charset
      else                              # Field.new("field-name", "value")
        @name = name
        @value = value
        @charset = charset
      end
      @name = FIELD_NAME_MAP[@name.to_s.downcase] || @name
    end

    def field=(value)
      @field = value
      @raw_source = nil
    end

    def field
      @field ||= create_field(name, raw_value)
    end

    attr_reader :name

    def value
      field.value
    end

    def value=(val)
      self.field = create_field(name, val)
    end

    def to_s
      field.to_s
    end

    def ready_to_send!
      unless @ready_to_send && @raw_source
        @ready_to_send = true
        @raw_source = field.encoded
      end
    end

    def encoded
      ready_to_send!
      encoded_as_is
    end

    def encoded_as_is
      @raw_source ||= field.encoded
      @raw_source << "\r\n" if @raw_source != "" && !@raw_source.end_with?("\r\n")
      @raw_source
    end

    def update(name, value)
      self.field = create_field(name, value)
    end

    def same( other )
      match_to_s(other.name, self.name)
    end

    def responsible_for?( val )
      name.to_s.casecmp(val.to_s) == 0
    end

    alias_method :==, :same

    def <=>( other )
      self.field_order_id <=> other.field_order_id
    end

    def field_order_id
      @field_order_id ||= (FIELD_ORDER_LOOKUP[self.name.to_s.downcase] || 100)
    end

    def method_missing(name, *args, &block)
      ret = field.send(name, *args, &block)
      @raw_source = nil if name.to_s.end_with?("=")
      ret
    end

    FIELD_ORDER = %w[ return-path received
                      resent-date resent-from resent-sender resent-to
                      resent-cc resent-bcc resent-message-id
                      date from sender reply-to to cc bcc
                      message-id in-reply-to references
                      subject comments keywords
                      mime-version content-type content-transfer-encoding
                      content-location content-disposition content-description ]

    FIELD_ORDER_LOOKUP = Hash[FIELD_ORDER.each_with_index.to_a]

    private

    def raw_value
      @value ||= @raw_source ? parse_raw_value : nil
    end

    def parse_raw_value
      if match = @raw_source.mb_chars.match(FIELD_VALUE)
        match[1].to_s.mb_chars.strip.to_s
      else
        STDERR.puts "WARNING: Could not parse (and so ignoring) #{@raw_source.inspect}"
      end
    end

    # 2.2.3. Long Header Fields
    #
    #  The process of moving from this folded multiple-line representation
    #  of a header field to its single line representation is called
    #  "unfolding". Unfolding is accomplished by simply removing any CRLF
    #  that is immediately followed by WSP.  Each header field should be
    #  treated in its unfolded form for further syntactic and semantic
    #  evaluation.
    def unfold(string)
      string.gsub(/[\r\n \t]+/m, ' ')
    end

    def create_field(name, value)
      value = unfold(value) if value.is_a?(String)

      begin
        new_field(name, value)
      rescue Mail::Field::ParseError => e
        field = Mail::UnstructuredField.new(name, value)
        field.errors << [name, value, e]
        field
      end
    end

    def new_field(name, value)
      lower_case_name = name.to_s.downcase
      if field_klass = FIELDS_MAP[lower_case_name]
        field_klass.new(value, @charset)
      else
        OptionalField.new(name, value, @charset)
      end
    end

  end

end
