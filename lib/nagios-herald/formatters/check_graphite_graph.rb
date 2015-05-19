# CheckGraphiteGraph formatter
# Downloads the Graphite graph used to trigger the alert.
# Also downloads an historical graph of the last 24 hours for comparison.

module NagiosHerald
  class Formatter
    class CheckGraphiteGraph < NagiosHerald::Formatter
      include NagiosHerald::Logging

      # Public: Retrieves Graphite graphs for the endpoint the check queried.
      # url - The URL for the Graphite endpoint the check queried.
      # Returns the file names of all retrieved graphs. These can be attached to the message.
      def get_graphite_graphs(url)
        begin
          graphite = NagiosHerald::Helpers::GraphiteGraph.new
          show_historical = true
          graphs =  graphite.get_graph(url, @sandbox, show_historical)
          return graphs
        rescue Exception => e
          logger.error "Exception encountered retrieving Graphite graphs - #{e.message}"
          e.backtrace.each do |line|
            logger.error "#{line}"
          end
          return []
        end
      end

      # Public: Overrides Formatter::Base#additional_info.
      # Returns nothing. Updates the formatter content hash.
      def additional_info
        section = __method__
        output = get_nagios_var("NAGIOS_#{@state_type}OUTPUT")
        # Output is formmated like: Current value: 18094.25, warn threshold: 100.0, crit threshold: 1000.0
        add_text(section, "Additional Info:\n #{unescape_text(output)}\n\n") if output
        output_match = output.match(/Current value: (?<current_value>[^,]*), warn threshold: (?<warn_threshold>[^,]*), crit threshold: (?<crit_threshold>[^,]*)/)
        if output_match
          add_html(section, "Current value: <b><font color='red'>#{output_match['current_value']}</font></b>, warn threshold: <b>#{output_match['warn_threshold']}</b>, crit threshold: <b><font color='red'>#{output_match['crit_threshold']}</font></b><br><br>")
        else
          add_html(section, "<b>Additional Info</b>:<br> #{output}<br><br>") if output
        end

        elasticsearch_section section

        graphs_section section
      end

      private

      def elasticsearch_section(section)
        queries = get_nagios_var("NAGIOS_ELASTICSEARCH_QUERIES")

        split_queries = queries.split(/,/)

        service_check_command = get_nagios_var("NAGIOS_SERVICECHECKCOMMAND")
        url = service_check_command.split(/!/)[-1].gsub(/'/, '')

        from_match = url.match(/from=-?(?<from>[^&]*)/)
        if from_match
          time_period = "10m"
        else
         add_html(section, "<b>View from the time of the Nagios check</b><br>")
        end

        elasticsearch_helper = NagiosHerald::Helpers::ElasticsearchQuery.new({ :time_period => time_period})

        for query in split_queries
          split_query = query.split(/\|/)

          add_html(section, "<b>#{split_query[0]}</b><br>")
          add_html(section, "<br>")

          results = get_elasticsearch_results(elasticsearch_helper, split_query[1])
        end
      end

      def graphs_section(section)
        # Get Graphite graphs.
        # Extract the Graphite URL from NAGIOS_SERVICECHECKCOMMAND
        service_check_command = get_nagios_var("NAGIOS_SERVICECHECKCOMMAND")
        url = service_check_command.split(/!/)[-1].gsub(/'/, '')
        graphite_graphs = get_graphite_graphs(url)
        from_match = url.match(/from=(?<from>[^&]*)/)
        if from_match
          add_html(section, "<b>View from '#{from_match['from']}' ago</b><br>")
        else
         add_html(section, "<b>View from the time of the Nagios check</b><br>")
        end
        add_attachment graphite_graphs[0]    # The original graph.
        add_html(section, %Q(<img src="#{graphite_graphs[0]}" alt="graphite_graph" /><br><br>))
        add_html(section, '<b>24-hour View</b><br>')
        add_attachment graphite_graphs[1]    # The 24-hour graph.
        add_html(section, %Q(<img src="#{graphite_graphs[1]}" alt="graphite_graph" /><br><br>))
      end

      def agg_depth(agg_data)
        agg_level = 0
        if agg_data.kind_of?(String)
          agg_level = agg_data.include?("aggs") || agg_data.include?("aggregations") ? 1 : 0
        else
          agg_data.each do |k,v|
            this_level = k.include?("aggs") || k.include?("aggregations") ? 1 : 0
            agg_level = this_level + agg_depth(v)
          end
        end
        agg_level
      end

      def get_elasticsearch_results(elasticsearch_helper, query)
        begin
          if query.include?(".json")
            elasticsearch_helper.query_from_file("/opt/nagios-herald/queries/#{query}")
          else
            elasticsearch_helper.query_from_string(query)
          end
        rescue Exception => e
          logger.error "Exception encountered retrieving Elasticsearch Query - #{e.message}"
          e.backtrace.each do |line|
            logger.error "#{line}"
          end
          return []
        end
      end

      def generate_html_output(results)
        output_prefix = "<table border='1' cellpadding='0' cellspacing='1'>"
        output_suffix = "</table>"

        headers = "<tr>#{results.first["_source"].keys.map{|h|"<th>#{h}</th>"}.join}</tr>"
        result_values = results.map{|r|r["_source"]}

        body = result_values.map{|r| "<tr>#{r.map{|k,v|"<td>#{v}</td>"}.join}</tr>"}.join

        output_prefix + headers + body + output_suffix
      end

      def generate_table_from_buckets(buckets)
        unique_keys = buckets.map{|b|b.keys}.flatten.uniq

        output_prefix = "<table border='1' cellpadding='0' cellspacing='1'>"
        output_suffix = "</table>"
        headers = "<tr>#{unique_keys.map{|h|"<th>#{h}</th>"}.join}</tr>"
        body = buckets.map do |r|
          generate_table_from_hash(r)
        end.join
        output_prefix + headers + body + output_suffix
      end

      def generate_table_from_hash(data,add_headers=false)
        output_prefix = "<table border='1' cellpadding='0' cellspacing='1'>"
        output_suffix = "</table>"
        headers = add_headers ? "<tr>#{data.keys.map{|h|"<th>#{h}</th>"}.join}</tr>" : ""
        body = "<tr>#{data.map do |k,v|
            if v.kind_of?(Hash)
              if v.has_key?("buckets")
                "<td>#{generate_table_from_buckets(v["buckets"])}</td>"
              else
                "<td>#{generate_table_from_hash(v,true)}</td>"
              end
            else
              "<td>#{v}</td>"
            end
        end.join}</tr>"

        if add_headers
          output_prefix + headers + body + output_suffix
        else
          body
        end
      end
    end
  end
end
