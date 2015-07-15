module Agents
  class DataOutputAgent < Agent
    cannot_be_scheduled!

    description  do
      <<-MD
        The Agent outputs received events as either RSS or JSON.  Use it to output a public or private stream of Huginn data.

        This Agent will output data at:

        `https://#{ENV['DOMAIN']}#{Rails.application.routes.url_helpers.web_requests_path(agent_id: ':id', user_id: user_id, secret: ':secret', format: :xml)}`

        where `:secret` is one of the allowed secrets specified in your options and the extension can be `xml` or `json`.

        You can setup multiple secrets so that you can individually authorize external systems to
        access your Huginn data.

        Options:

          * `secrets` - An array of tokens that the requestor must provide for light-weight authentication.
          * `expected_receive_period_in_days` - How often you expect data to be received by this Agent from other Agents.
          * `template` - A JSON object representing a mapping between item output keys and incoming event values.  Use [Liquid](https://github.com/cantino/huginn/wiki/Formatting-Events-using-Liquid) to format the values.  Values of the `link`, `title`, `description` and `icon` keys will be put into the \\<channel\\> section of RSS output.  The `item` key will be repeated for every Event.  The `pubDate` key for each item will have the creation time of the Event unless given.
          * `events_to_show` - The number of events to output in RSS or JSON. (default: `40`)
          * `ttl` - A value for the \\<ttl\\> element in RSS output. (default: `60`)
          * `order_by` - A Liquid expression to reorder the last `events_to_show` events by, for example `{{title}}`.  Default behavior is no reordering.
          * `order_direction` - The direction to reorder by if `order_by` is provided.  Either `asc` (default) or `desc`.

        If you'd like to output RSS tags with attributes, such as `enclosure`, use something like the following in your `template`:

            "enclosure": {
              "_attributes": {
                "url": "{{media_url}}",
                "length": "1234456789",
                "type": "audio/mpeg"
              }
            },
            "another_tag": {
              "_attributes": {
                "key": "value",
                "another_key": "another_value"
              },
              "_contents": "tag contents (can be an object for nesting)"
            }

        # Liquid Templating

        In Liquid templating, the following variable is available:

        * `events`: An array of events being output, sorted in the given order, up to `events_to_show` in number.  For example, if source events contain a site title in the `site_title` key, you can refer to it in `template.title` by putting `{{events.first.site_title}}`.

      MD
    end

    def default_options
      {
        "secrets" => ["a-secret-key"],
        "expected_receive_period_in_days" => 2,
        "template" => {
          "title" => "XKCD comics as a feed",
          "description" => "This is a feed of recent XKCD comics, generated by Huginn",
          "item" => {
            "title" => "{{title}}",
            "description" => "Secret hovertext: {{hovertext}}",
            "link" => "{{url}}"
          }
        }
      }
    end

    def working?
      last_receive_at && last_receive_at > options['expected_receive_period_in_days'].to_i.days.ago && !recent_error_logs?
    end

    def validate_options
      if options['secrets'].is_a?(Array) && options['secrets'].length > 0
        options['secrets'].each do |secret|
          case secret
          when %r{[/.]}
            errors.add(:base, "secret may not contain a slash or dot")
          when String
          else
            errors.add(:base, "secret must be a string")
          end
        end
      else
        errors.add(:base, "Please specify one or more secrets for 'authenticating' incoming feed requests")
      end

      unless options['expected_receive_period_in_days'].present? && options['expected_receive_period_in_days'].to_i > 0
        errors.add(:base, "Please provide 'expected_receive_period_in_days' to indicate how many days can pass before this Agent is considered to be not working")
      end

      unless options['template'].present? && options['template']['item'].present? && options['template']['item'].is_a?(Hash)
        errors.add(:base, "Please provide template and template.item")
      end
    end

    def events_to_show
      (interpolated['events_to_show'].presence || 40).to_i
    end

    def feed_ttl
      (interpolated['ttl'].presence || 60).to_i
    end

    def feed_title
      interpolated['template']['title'].presence || "#{name} Event Feed"
    end

    def feed_link
      interpolated['template']['link'].presence || "https://#{ENV['DOMAIN']}"
    end

    def feed_url(options = {})
      feed_link + Rails.application.routes.url_helpers.
                  web_requests_path(agent_id: id || ':id',
                                    user_id: user_id,
                                    secret: options[:secret],
                                    format: options[:format])
    end

    def feed_icon
      interpolated['template']['icon'].presence || feed_link + '/favicon.ico'
    end

    def feed_description
      interpolated['template']['description'].presence || "A feed of Events received by the '#{name}' Huginn Agent"
    end

    def receive_web_request(params, method, format)
      unless interpolated['secrets'].include?(params['secret'])
        if format =~ /json/
          return [{ error: "Not Authorized" }, 401]
        else
          return ["Not Authorized", 401]
        end
      end

      source_events = received_events.order(id: :desc).limit(events_to_show).to_a

      interpolation_context.stack do
        sort_events! source_events
        
        interpolation_context['events'] = source_events

        items = source_events.map do |event|
          interpolated = interpolate_options(options['template']['item'], event)
          interpolated['guid'] = {'_attributes' => {'isPermaLink' => 'false'},
                                  '_contents' => interpolated['guid'].presence || event.id}
          date_string = interpolated['pubDate'].to_s
          date =
            begin
              Time.zone.parse(date_string)  # may return nil
            rescue => e
              error "Error parsing a \"pubDate\" value \"#{date_string}\": #{e.message}"
              nil
            end || event.created_at
          interpolated['pubDate'] = date.rfc2822.to_s
          interpolated
        end

        if format =~ /json/
          content = {
            'title' => feed_title,
            'description' => feed_description,
            'pubDate' => Time.now,
            'items' => simplify_item_for_json(items)
          }

          return [content, 200]
        else
          content = Utils.unindent(<<-XML)
            <?xml version="1.0" encoding="UTF-8" ?>
            <rss version="2.0" xmlns:atom="http://www.w3.org/2005/Atom">
            <channel>
             <atom:link href=#{feed_url(secret: params['secret'], format: :xml).encode(xml: :attr)} rel="self" type="application/rss+xml" />
             <atom:icon>#{feed_icon.encode(xml: :text)}</atom:icon>
             <title>#{feed_title.encode(xml: :text)}</title>
             <description>#{feed_description.encode(xml: :text)}</description>
             <link>#{feed_link.encode(xml: :text)}</link>
             <lastBuildDate>#{Time.now.rfc2822.to_s.encode(xml: :text)}</lastBuildDate>
             <pubDate>#{Time.now.rfc2822.to_s.encode(xml: :text)}</pubDate>
             <ttl>#{feed_ttl}</ttl>

          XML

          content += simplify_item_for_xml(items).to_xml(skip_types: true, root: "items", skip_instruct: true, indent: 1).gsub(/^<\/?items>/, '').strip

          content += Utils.unindent(<<-XML)
            </channel>
            </rss>
          XML

          return [content, 200, 'text/xml']
        end
      end
    end

    private

    class XMLNode
      def initialize(tag_name, attributes, contents)
        @tag_name, @attributes, @contents = tag_name, attributes, contents
      end

      def to_xml(options)
        if @contents.is_a?(Hash)
          options[:builder].tag! @tag_name, @attributes do
            @contents.each { |key, value| ActiveSupport::XmlMini.to_tag(key, value, options.merge(skip_instruct: true)) }
          end
        else
          options[:builder].tag! @tag_name, @attributes, @contents
        end
      end
    end

    def simplify_item_for_xml(item)
      if item.is_a?(Hash)
        item.each.with_object({}) do |(key, value), memo|
          if value.is_a?(Hash)
            if value.key?('_attributes') || value.key?('_contents')
              memo[key] = XMLNode.new(key, value['_attributes'], simplify_item_for_xml(value['_contents']))
            else
              memo[key] = simplify_item_for_xml(value)
            end
          else
            memo[key] = value
          end
        end
      elsif item.is_a?(Array)
        item.map { |value| simplify_item_for_xml(value) }
      else
        item
      end
    end

    def simplify_item_for_json(item)
      if item.is_a?(Hash)
        item.each.with_object({}) do |(key, value), memo|
          if value.is_a?(Hash)
            if value.key?('_attributes') || value.key?('_contents')
              contents = if value['_contents'] && value['_contents'].is_a?(Hash)
                           simplify_item_for_json(value['_contents'])
                         elsif value['_contents']
                           { "contents" => value['_contents'] }
                         else
                           {}
                         end

              memo[key] = contents.merge(value['_attributes'] || {})
            else
              memo[key] = simplify_item_for_json(value)
            end
          else
            memo[key] = value
          end
        end
      elsif item.is_a?(Array)
        item.map { |value| simplify_item_for_json(value) }
      else
        item
      end
    end

    def sort_events!(source_events)
      return unless options['order_by'].present?

      source_events.sort! do |event_a, event_b|
        event_a, event_b = event_b, event_a if interpolated['order_direction'] == 'desc'
        interpolate_options(options['order_by'], event_a) <=> interpolate_options(options['order_by'], event_b)
      end
    end
  end
end
