require 'csv'

class MyObfuscate
  class Csv
    def invert_column_map(column_mapper)
      column_mapper.inject({}) do |memo, (k,v)|
        v.is_a?(Array) ? v.map{|f| memo[f] = k} : memo[v] = k
        memo[k] = k # auto maps itself
        memo
      end
    end

    def parse(obfuscator, config, input_io, output_io)
      column_mapper = config[:column_mapper] || {}
      config.delete(:column_mapper)

      inverted_mapper = invert_column_map(column_mapper)

      @column_data = column_mapper.keys.inject({}) do |memo, k|
        memo[k] = {}
        memo
      end

      raise "CSV files must have a header row" unless obfuscator.csv_headers

      table_config = config[:csv]

      CSV(output_io) do |csv_out|
        CSV(input_io, headers: obfuscator.csv_headers,
                      col_sep: obfuscator.csv_col_sep,
                      encoding: obfuscator.csv_encoding) do |csv_in|

          headers_written = false

          csv_in.each do |line|
            headers = csv_in.headers
            (csv_out << headers and headers_written = true) unless headers_written

            matched = {}
            old_values = {}

            unless column_mapper.empty?
              headers.each_with_index do |col, i|
                if column_mapper[col]
                  old_value = line[col]
                  if @column_data[col][old_value]
                    matched[i] = @column_data[col][old_value]
                  else
                    old_values[i] = old_value
                  end
                end
              end
            end

            obfuscated = ConfigApplicator.apply_table_config(line.to_hash.values, table_config, headers)

            # stores new data for successive rows
            old_values.each do |i, old_value|
              data_col = inverted_mapper[headers[i]]
              @column_data[data_col][old_value] = obfuscated[i]
            end

            # Check to see if any dependent columns should be updated
            unless inverted_mapper.empty?
              headers.each_with_index do |col, i|
                mapped_col = inverted_mapper[col]

                if mapped_col
                  replace_value = @column_data[mapped_col][line[col]]
                  matched[i] = replace_value || obfuscated[i]
                end
              end
            end

            obfuscated_as_indexed_hash = {}
            obfuscated.each_with_index {|v,i| obfuscated_as_indexed_hash[i] = v}

            csv_out << obfuscated_as_indexed_hash.merge(matched).values
          end
        end
      end
    end

  end
end
