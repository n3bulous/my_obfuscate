require 'csv'

class MyObfuscate
  class Csv
    def parse(obfuscator, config, input_io, output_io)
      @column_mapper = config[:column_mapper] || {}
      config.delete(:column_mapper)

      @column_data = @column_mapper.keys.inject({}) do |memo, k|
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

            unless @column_mapper.empty?
              headers.each_with_index do |col, i|
                if @column_mapper[col]
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

            old_values.each do |i, old_value|
              @column_data[headers[i]][old_value] = obfuscated[i]
            end

            csv_out << obfuscated.each_with_index.to_h.invert.merge(matched).values
          end
        end
      end
    end

  end
end
