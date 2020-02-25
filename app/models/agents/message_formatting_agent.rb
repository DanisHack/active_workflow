module Agents
  class MessageFormattingAgent < Agent
    cannot_be_scheduled!
    can_dry_run!

    description <<-MD
      The Message Formatting Agent allows you to format incoming Messages, adding new fields as needed.

      For example, here is a possible Message:

          {
            "high": {
              "celsius": "18",
              "fahreinheit": "64"
            },
            "date": {
              "epoch": "1357959600",
              "pretty": "10:00 PM EST on January 11, 2013"
            },
            "conditions": "Rain showers",
            "data": "This is some data"
          }

      You may want to send this message to another Agent, for example a Twilio Agent, which expects a `message` key.
      You can use an Message Formatting Agent's `instructions` setting to do this in the following way:

          "instructions": {
            "message": "Today's conditions look like {{conditions}} with a high temperature of {{high.celsius}} degrees Celsius.",
            "subject": "{{data}}",
            "created_at": "{{created_at}}"
          }

      Names here like `conditions`, `high` and `data` refer to the corresponding values in the Message hash.

      The special key `created_at` refers to the timestamp of the Message, which can be reformatted by the `date` filter, like `{{created_at | date:"at %I:%M %p" }}`.

      You can use [Liquid templating](https://shopify.github.io/liquid/) to configure this agent.

      Messages generated by this Message Formatting Agent will look like:

          {
            "message": "Today's conditions look like Rain showers with a high temperature of 18 degrees Celsius.",
            "subject": "This is some data"
          }

      In `matchers` setting you can perform regular expression matching against contents of messages and expand the match data for use in `instructions` setting.  Here is an example:

          {
            "matchers": [
              {
                "path": "{{date.pretty}}",
                "regexp": "\\A(?<time>\\d\\d:\\d\\d [AP]M [A-Z]+)",
                "to": "pretty_date"
              }
            ]
          }

      This virtually merges the following hash into the original message hash:

          "pretty_date": {
            "time": "10:00 PM EST",
            "0": "10:00 PM EST on January 11, 2013"
            "1": "10:00 PM EST"
          }

      So you can use it in `instructions` like this:

          "instructions": {
            "message": "Today's conditions look like {{conditions}} with a high temperature of {{high.celsius}} degrees Celsius according to the forecast at {{pretty_date.time}}.",
            "subject": "{{data}}"
          }

      If you want to retain original contents of messages and only add new keys, then set `mode` to `merge`, otherwise set it to `clean`.

      To CGI escape output (for example when creating a link), use the Liquid `uri_escape` filter, like so:

          {
            "message": "A peak was on Twitter in {{group_by}}.  Search: https://twitter.com/search?q={{group_by | uri_escape}}"
          }
    MD

    message_description do
      mode_text = case options['mode'].to_s
                  when 'merge'
                    ', merged with the original contents'
                  when /\{/
                    ', conditionally merged with the original contents'
                  end
      format(
        "Messages will have the following fields%s:\n\n    %s",
        mode_text,
        Utils.pretty_print(Hash[options['instructions'].keys.map { |key|
          [key, '...']
        }])
      )
    end

    def validate_options
      errors.add(:base, 'instructions and mode need to be present.') unless options['instructions'].present? && options['mode'].present?

      if options['mode'].present? && !options['mode'].to_s.include?('{{') && !%(clean merge).include?(options['mode'].to_s)
        errors.add(:base, "mode must be 'clean' or 'merge'")
      end

      validate_matchers
    end

    def default_options
      {
        'instructions' => {
          'message' =>  'You received a text {{text}} from {{fields.from}}',
          'some_other_field' => 'Looks like the weather is going to be {{fields.weather}}'
        },
        'matchers' => [],
        'mode' => 'clean'
      }
    end

    def receive(message)
      matchers = compiled_matchers

      interpolate_with(message) do
        apply_compiled_matchers(matchers, message) do
          formatted_message = interpolated['mode'].to_s == 'merge' ? message.payload.dup : {}
          formatted_message.merge! interpolated['instructions']
          create_message payload: formatted_message
        end
      end
    end

    private

    # rubocop:disable Metrics/PerceivedComplexity
    # rubocop:disable Metrics/CyclomaticComplexity
    def validate_matchers
      matchers = options['matchers'] or return

      unless matchers.is_a?(Array)
        errors.add(:base, 'matchers must be an array if present')
        return
      end

      matchers.each do |matcher|
        unless matcher.is_a?(Hash)
          errors.add(:base, 'each matcher must be a hash')
          next
        end

        regexp, path, to = matcher.values_at('regexp', 'path', 'to')

        if regexp.present?
          begin
            Regexp.new(regexp)
          rescue StandardError
            errors.add(:base, "bad regexp found in matchers: #{regexp}")
          end
        else
          errors.add(:base, 'regexp is mandatory for a matcher and must be a string')
        end

        errors.add(:base, 'path is mandatory for a matcher and must be a string') unless path.present?

        errors.add(:base, 'to must be a string if present in a matcher') if to.present? && !to.is_a?(String)
      end
    end
    # rubocop:enable Metrics/PerceivedComplexity
    # rubocop:enable Metrics/CyclomaticComplexity

    def compiled_matchers
      return unless (matchers = options['matchers'])
      matchers.map { |matcher|
        regexp, path, to = matcher.values_at('regexp', 'path', 'to')
        [Regexp.new(regexp), path, to]
      }
    end

    def apply_compiled_matchers(matchers, message, &block)
      return yield if matchers.nil?

      # message.payload.dup does not work; HashWithIndifferentAccess is
      # a source of trouble here.
      hash = {}.update(message.payload)

      matchers.each do |re, path, to|
        m = re.match(interpolate_string(path, hash)) or next

        mhash =
          if to
            case value = hash[to]
            when Hash
              value
            else
              hash[to] = {}
            end
          else
            hash
          end

        m.size.times do |i|
          mhash[i.to_s] = m[i]
        end

        m.names.each do |name|
          mhash[name] = m[name]
        end
      end

      interpolate_with(hash, &block)
    end
  end
end
