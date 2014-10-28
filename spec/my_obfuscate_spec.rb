require 'spec_helper'

describe MyObfuscate do
  describe "MyObfuscate.reassembling_each_insert" do
    before do
      @column_names = [:a, :b, :c, :d]
      @test_insert = "INSERT INTO `some_table` (`a`, `b`, `c`, `d`) VALUES ('(\\'bob@bob.com','b()ob','some(thingelse1','25)('),('joe@joe.com','joe','somethingelse2','54');"
      @test_insert_passes = [
          ["(\\'bob@bob.com", "b()ob", "some(thingelse1", "25)("],
          ["joe@joe.com", "joe", "somethingelse2", "54"]
      ]
    end

    it "should yield each subinsert and reassemble the result" do
      count = 0
      reassembled = MyObfuscate.new.reassembling_each_insert(@test_insert, "some_table", @column_names) do |sub_insert|
        expect(sub_insert).to eq(@test_insert_passes.shift)
        count += 1
        sub_insert
      end
      expect(count).to eq(2)
      expect(reassembled).to eq(@test_insert)
    end
  end

  describe "#obfuscate" do

    describe "when using Postgres" do
      let(:dump) do
        StringIO.new(<<-SQL)
COPY some_table (id, email, name, something, age) FROM stdin;
1	hello	monkey	moose	14
\.

COPY single_column_table (id) FROM stdin;
1
2
\\N
\.

COPY another_table (a, b, c, d) FROM stdin;
1	2	3	4
1	2	3	4
\.

COPY some_table_to_keep (a, b) FROM stdin;
5	6
\.
        SQL
      end

      let(:obfuscator) do
        MyObfuscate.new({
          :some_table => {
            :email => {:type => :email, :skip_regexes => [/^[\w\.\_]+@honk\.com$/i, /^dontmurderme@direwolf.com$/]},
            :name => {:type => :string, :length => 8, :chars => MyObfuscate::USERNAME_CHARS},
            :age => {:type => :integer, :between => 10...80, :unless => :nil },
          },
          :single_column_table => {
            :id => {:type => :integer, :between => 2..9, :unless => :nil}
          },
          :another_table => :truncate,
          :some_table_to_keep => :keep
        }).tap do |obfuscator|
          obfuscator.database_type = :postgres
        end
      end

      let(:output_string) do
        output = StringIO.new
        obfuscator.obfuscate(dump, output)
        output.rewind
        output.read
      end

      it "is able to obfuscate single column tables" do
        expect(output_string).not_to include("1\n2\n")
        expect(output_string).to match(/\d\n\d\n/)
      end

      it "is able to truncate tables" do
        expect(output_string).not_to include("1\t2\t3\t4")
      end

      it "can obfuscate the tables" do
        expect(output_string).to include("COPY some_table (id, email, name, something, age) FROM stdin;\n")
        expect(output_string).to match(/1\t.*\t\S{8}\tmoose\t\d{2}\n/)
      end

      it "can skip nils" do
        expect(output_string).to match(/\d\n\d\n\\N/)
      end

      it "is able to keep tables" do
        expect(output_string).to include("5\t6")
      end

      context "when dump contains INSERT statement" do
        let(:dump) do
          StringIO.new(<<-SQL)
          INSERT INTO some_table (email, name, something, age) VALUES ('','', '', 25);
          SQL
        end

        it "raises an error if using postgres with insert statements" do
          expect { output_string }.to raise_error RuntimeError
        end
      end
    end

    describe "when using MySQL" do
      context "when there is nothing to obfuscate" do
        it "should accept an IO object for input and output, and copy the input to the output" do
          ddo = MyObfuscate.new
          string = "hello, world\nsup?"
          input = StringIO.new(string)
          output = StringIO.new
          ddo.obfuscate(input, output)
          input.rewind
          output.rewind
          expect(output.read).to eq(string)
        end
      end

      context "when the dump to obfuscate is missing columns" do
        before do
          @database_dump = StringIO.new(<<-SQL)
          INSERT INTO `some_table` (`email`, `name`, `something`, `age`) VALUES ('bob@honk.com','bob', 'some\\'thin,ge())lse1', 25),('joe@joe.com','joe', 'somethingelse2', 54);
          SQL
          @ddo = MyObfuscate.new({
                                     :some_table => {
                                         :email => {:type => :email, :honk_email_skip => true},
                                         :name => {:type => :string, :length => 8, :chars => MyObfuscate::USERNAME_CHARS},
                                         :gender => {:type => :fixed, :string => "m"}
                                     }})
          @output = StringIO.new
        end

        it "should raise an error if a column name can't be found" do
          expect {
            @ddo.obfuscate(@database_dump, @output)
          }.to raise_error
        end
      end

      context "when there is something to obfuscate" do
        before do
          @database_dump = StringIO.new(<<-SQL)
          INSERT INTO `some_table` (`email`, `name`, `something`, `age`) VALUES ('bob@honk.com','bob', 'some\\'thin,ge())lse1', 25),('joe@joe.com','joe', 'somethingelse2', 54),('dontmurderme@direwolf.com','direwolf', 'somethingelse3', 44);
          INSERT INTO `another_table` (`a`, `b`, `c`, `d`) VALUES (1,2,3,4), (5,6,7,8);
          INSERT INTO `some_table_to_keep` (`a`, `b`, `c`, `d`) VALUES (1,2,3,4), (5,6,7,8);
          INSERT INTO `one_more_table` (`a`, `password`, `c`, `d,d`) VALUES ('hello','kjhjd^&dkjh', 'aawefjkafe'), ('hello1','kjhj!', 892938), ('hello2','moose!!', NULL);
          INSERT INTO `an_ignored_table` (`col`, `col2`) VALUES ('hello','kjhjd^&dkjh'), ('hello1','kjhj!'), ('hello2','moose!!');
          SQL

          @ddo = MyObfuscate.new({
                                     :some_table => {
                                         :email => {:type => :email, :skip_regexes => [/^[\w\.\_]+@honk\.com$/i, /^dontmurderme@direwolf.com$/]},
                                         :name => {:type => :string, :length => 8, :chars => MyObfuscate::USERNAME_CHARS},
                                         :age => {:type => :integer, :between => 10...80}
                                     },
                                     :another_table => :truncate,
                                     :some_table_to_keep => :keep,
                                     :one_more_table => {
                                         # Note: fixed strings must be pre-SQL escaped!
                                         :password => {:type => :fixed, :string => "monkey"},
                                         :c => {:type => :null}
                                     }
                                 })
          @output = StringIO.new
          $stderr = @error_output = StringIO.new
          @ddo.obfuscate(@database_dump, @output)
          $stderr = STDERR
          @output.rewind
          @output_string = @output.read
        end

        it "should be able to truncate tables" do
          expect(@output_string).not_to include("INSERT INTO `another_table`")
          expect(@output_string).to include("INSERT INTO `one_more_table`")
        end

        it "should be able to declare tables to keep" do
          expect(@output_string).to include("INSERT INTO `some_table_to_keep` (`a`, `b`, `c`, `d`) VALUES (1,2,3,4), (5,6,7,8);")
        end

        it "should ignore tables that it doesn't know about, but should warn" do
          expect(@output_string).to include("INSERT INTO `an_ignored_table` (`col`, `col2`) VALUES ('hello','kjhjd^&dkjh'), ('hello1','kjhj!'), ('hello2','moose!!');")
          @error_output.rewind
          expect(@error_output.read).to match(/an_ignored_table was not specified in the config/)
        end

        it "should obfuscate the tables" do
          expect(@output_string).to include("INSERT INTO `some_table` (`email`, `name`, `something`, `age`) VALUES (")
          expect(@output_string).to include("INSERT INTO `one_more_table` (`a`, `password`, `c`, `d,d`) VALUES (")
          expect(@output_string).to include("'some\\'thin,ge())lse1'")
          expect(@output_string).to include("INSERT INTO `one_more_table` (`a`, `password`, `c`, `d,d`) VALUES ('hello','monkey',NULL),('hello1','monkey',NULL),('hello2','monkey',NULL);")
          expect(@output_string).not_to include("INSERT INTO `one_more_table` (`a`, `password`, `c`, `d,d`) VALUES ('hello','kjhjd^&dkjh', 'aawefjkafe'), ('hello1','kjhj!', 892938), ('hello2','moose!!', NULL);")
          expect(@output_string).not_to include("INSERT INTO `one_more_table` (`a`, `password`, `c`, `d,d`) VALUES ('hello','kjhjd^&dkjh','aawefjkafe'),('hello1','kjhj!',892938),('hello2','moose!!',NULL);")
          expect(@output_string).not_to include("INSERT INTO `some_table` (`email`, `name`, `something`, `age`) VALUES ('bob@honk.com','bob', 'some\\'thin,ge())lse1', 25),('joe@joe.com','joe', 'somethingelse2', 54);")
        end

        it "honors a special case: on the people table, rows with skip_regexes that match are skipped" do
          expect(@output_string).to include("('bob@honk.com',")
          expect(@output_string).to include("('dontmurderme@direwolf.com',")
          expect(@output_string).not_to include("joe@joe.com")
          expect(@output_string).to include("example.com")
        end
      end

      context "when fail_on_unspecified_columns is set to true" do
        before do
          @database_dump = StringIO.new(<<-SQL)
          INSERT INTO `some_table` (`email`, `name`, `something`, `age`) VALUES ('bob@honk.com','bob', 'some\\'thin,ge())lse1', 25),('joe@joe.com','joe', 'somethingelse2', 54),('dontmurderme@direwolf.com','direwolf', 'somethingelse3', 44);
          SQL

          @ddo = MyObfuscate.new({
                                     :some_table => {
                                         :email => {:type => :email, :skip_regexes => [/^[\w\.\_]+@honk\.com$/i, /^dontmurderme@direwolf.com$/]},
                                         :name => {:type => :string, :length => 8, :chars => MyObfuscate::USERNAME_CHARS},
                                         :age => {:type => :integer, :between => 10...80}
                                     }
                                 })
          @ddo.fail_on_unspecified_columns = true
        end

        it "should raise an exception when an unspecified column is found" do
          expect {
            @ddo.obfuscate(@database_dump, StringIO.new)
          }.to raise_error(/column 'something' defined/i)
        end

        it "should accept columns defined in globally_kept_columns" do
          @ddo.globally_kept_columns = %w[something]
          expect {
            @ddo.obfuscate(@database_dump, StringIO.new)
          }.not_to raise_error
        end
      end
    end

    describe "when using MS SQL Server" do
      context "when there is nothing to obfuscate" do
        it "should accept an IO object for input and output, and copy the input to the output" do
          ddo = MyObfuscate.new
          ddo.database_type = :sql_server
          string = "hello, world\nsup?"
          input = StringIO.new(string)
          output = StringIO.new
          ddo.obfuscate(input, output)
          input.rewind
          output.rewind
          expect(output.read).to eq(string)
        end
      end

      context "when the dump to obfuscate is missing columns" do
        before do
          @database_dump = StringIO.new(<<-SQL)
          INSERT [dbo].[some_table] ([email], [name], [something], [age]) VALUES ('bob@honk.com','bob', 'some''thin,ge())lse1', 25);
          SQL
          @ddo =  MyObfuscate.new({
              :some_table => {
                  :email => {:type => :email, :honk_email_skip => true},
                  :name => {:type => :string, :length => 8, :chars => MyObfuscate::USERNAME_CHARS},
                  :gender => {:type => :fixed, :string => "m"}
              }})
          @ddo.database_type = :sql_server
          @output = StringIO.new
        end

        it "should raise an error if a column name can't be found" do
          expect {
            @ddo.obfuscate(@database_dump, @output)
          }.to raise_error
        end
      end

      context "when there is something to obfuscate" do
        before do
          @database_dump = StringIO.new(<<-SQL)
          INSERT [dbo].[some_table] ([email], [name], [something], [age], [bday]) VALUES (N'bob@honk.com',N'bob', N'some''thin,ge())lse1', 25, CAST(0x00009E1A00000000 AS DATETIME));
          INSERT [dbo].[some_table] ([email], [name], [something], [age], [bday]) VALUES (N'joe@joe.com',N'joe', N'somethingelse2', 54, CAST(0x00009E1A00000000 AS DATETIME));
          INSERT [dbo].[some_table] ([email], [name], [something], [age], [bday]) VALUES (N'dontmurderme@direwolf.com',N'direwolf', N'somethingelse3', 44, CAST(0x00009E1A00000000 AS DATETIME));
          INSERT [dbo].[another_table] ([a], [b], [c], [d]) VALUES (1,2,3,4);
          INSERT [dbo].[another_table] ([a], [b], [c], [d]) VALUES (5,6,7,8);
          INSERT [dbo].[some_table_to_keep] ([a], [b], [c], [d]) VALUES (1,2,3,4);
          INSERT [dbo].[some_table_to_keep] ([a], [b], [c], [d]) VALUES (5,6,7,8);
          INSERT [dbo].[one_more_table] ([a], [password], [c], [d,d]) VALUES (N'hello',N'kjhjd^&dkjh', N'aawefjkafe');
          INSERT [dbo].[one_more_table] ([a], [password], [c], [d,d]) VALUES (N'hello1',N'kjhj!', 892938);
          INSERT [dbo].[one_more_table] ([a], [password], [c], [d,d]) VALUES (N'hello2',N'moose!!', NULL);
          INSERT [dbo].[an_ignored_table] ([col], [col2]) VALUES (N'hello',N'kjhjd^&dkjh');
          INSERT [dbo].[an_ignored_table] ([col], [col2]) VALUES (N'hello1',N'kjhj!');
          INSERT [dbo].[an_ignored_table] ([col], [col2]) VALUES (N'hello2',N'moose!!');
          SQL

          @ddo = MyObfuscate.new({
               :some_table => {
                   :email => {:type => :email, :skip_regexes => [/^[\w\.\_]+@honk\.com$/i, /^dontmurderme@direwolf.com$/]},
                   :name => {:type => :string, :length => 8, :chars => MyObfuscate::USERNAME_CHARS},
                   :age => {:type => :integer, :between => 10...80},
                   :bday => :keep
               },
               :another_table => :truncate,
               :some_table_to_keep => :keep,
               :one_more_table => {
                   # Note: fixed strings must be pre-SQL escaped!
                   :password => {:type => :fixed, :string => "monkey"},
                   :c => {:type => :null}
               }
           })
          @ddo.database_type = :sql_server

          @output = StringIO.new
          $stderr = @error_output = StringIO.new
          @ddo.obfuscate(@database_dump, @output)
          $stderr = STDERR
          @output.rewind
          @output_string = @output.read
        end

        it "should be able to truncate tables" do
          expect(@output_string).not_to include("INSERT [dbo].[another_table]")
          expect(@output_string).to include("INSERT [dbo].[one_more_table]")
        end

        it "should be able to declare tables to keep" do
          expect(@output_string).to include("INSERT [dbo].[some_table_to_keep] ([a], [b], [c], [d]) VALUES (1,2,3,4);")
          expect(@output_string).to include("INSERT [dbo].[some_table_to_keep] ([a], [b], [c], [d]) VALUES (5,6,7,8);")
        end

        it "should ignore tables that it doesn't know about, but should warn" do
          expect(@output_string).to include("INSERT [dbo].[an_ignored_table] ([col], [col2]) VALUES (N'hello',N'kjhjd^&dkjh');")
          expect(@output_string).to include("INSERT [dbo].[an_ignored_table] ([col], [col2]) VALUES (N'hello1',N'kjhj!');")
          expect(@output_string).to include("INSERT [dbo].[an_ignored_table] ([col], [col2]) VALUES (N'hello2',N'moose!!');")
          @error_output.rewind
          expect(@error_output.read).to match(/an_ignored_table was not specified in the config/)
        end

        it "should obfuscate the tables" do
          expect(@output_string).to include("INSERT [dbo].[some_table] ([email], [name], [something], [age], [bday]) VALUES (")
          expect(@output_string).to include("CAST(0x00009E1A00000000 AS DATETIME)")
          expect(@output_string).to include("INSERT [dbo].[one_more_table] ([a], [password], [c], [d,d]) VALUES (")
          expect(@output_string).to include("'some''thin,ge())lse1'")
          expect(@output_string).to include("INSERT [dbo].[one_more_table] ([a], [password], [c], [d,d]) VALUES (N'hello',N'monkey',NULL);")
          expect(@output_string).to include("INSERT [dbo].[one_more_table] ([a], [password], [c], [d,d]) VALUES (N'hello1',N'monkey',NULL);")
          expect(@output_string).to include("INSERT [dbo].[one_more_table] ([a], [password], [c], [d,d]) VALUES (N'hello2',N'monkey',NULL);")
          expect(@output_string).not_to include("INSERT [dbo].[one_more_table] ([a], [password], [c], [d,d]) VALUES (N'hello',N'kjhjd^&dkjh', N'aawefjkafe');")
          expect(@output_string).not_to include("INSERT [dbo].[one_more_table] ([a], [password], [c], [d,d]) VALUES (N'hello1',N'kjhj!', 892938);")
          expect(@output_string).not_to include("INSERT [dbo].[one_more_table] ([a], [password], [c], [d,d]) VALUES (N'hello2',N'moose!!', NULL);")
          expect(@output_string).not_to include("INSERT [dbo].[some_table] ([email], [name], [something], [age]) VALUES (N'bob@honk.com',N'bob', N'some''thin,ge())lse1', 25, CAST(0x00009E1A00000000 AS DATETIME));")
          expect(@output_string).not_to include("INSERT [dbo].[some_table] ([email], [name], [something], [age]) VALUES (N'joe@joe.com',N'joe', N'somethingelse2', 54, CAST(0x00009E1A00000000 AS DATETIME));")
        end

        it "honors a special case: on the people table, rows with anything@honk.com in a slot marked with :honk_email_skip do not change this slot" do
          expect(@output_string).to include("(N'bob@honk.com',")
          expect(@output_string).to include("(N'dontmurderme@direwolf.com',")
          expect(@output_string).not_to include("joe@joe.com")
        end
      end

      context "when fail_on_unspecified_columns is set to true" do
        before do
          @database_dump = StringIO.new(<<-SQL)
          INSERT INTO [dbo].[some_table] ([email], [name], [something], [age]) VALUES ('bob@honk.com','bob', 'some''thin,ge())lse1', 25);
          SQL

          @ddo = MyObfuscate.new({
                                     :some_table => {
                                         :email => {:type => :email, :skip_regexes => [/^[\w\.\_]+@honk\.com$/i, /^dontmurderme@direwolf.com$/]},
                                         :name => {:type => :string, :length => 8, :chars => MyObfuscate::USERNAME_CHARS},
                                         :age => {:type => :integer, :between => 10...80}
                                     }
                                 })
          @ddo.database_type = :sql_server
          @ddo.fail_on_unspecified_columns = true
        end

        it "should raise an exception when an unspecified column is found" do
          expect {
            @ddo.obfuscate(@database_dump, StringIO.new)
          }.to raise_error(/column 'something' defined/i)
        end

        it "should accept columns defined in globally_kept_columns" do
          @ddo.globally_kept_columns = %w[something]
          expect {
            @ddo.obfuscate(@database_dump, StringIO.new)
          }.not_to raise_error
        end
      end
    end

    describe "when using CSV", focus: true do
      context "when processing a csv file without a header row" do
        it "aborts processing" do
          ddo = MyObfuscate.new
          ddo.database_type = :csv
          ddo.csv_headers = false

          string = "col1,col2,col3\n"
          input = StringIO.new(string)
          output = StringIO.new
          expect {
            ddo.obfuscate(input, output)
          }.to raise_error(Exception)
        end
      end

      context "when there is nothing to obfuscate" do
        it "returns the input data" do
          ddo = MyObfuscate.new
          ddo.database_type = :csv
          ddo.csv_headers = true

          header = "col1,col2,col3\n"
          row = "val1,val2,val3\n"
          string = header + row
          input = StringIO.new(string)
          output = StringIO.new
          ddo.obfuscate(input, output)
          output.rewind
          expect(output.read).to eq(string)
        end
      end

      context "when obfuscating a column without matching" do
        before do
          @ddo = MyObfuscate.new({
            csv: {
              "col1" => {:type => :string, :length => 8}
            }
          })
          @ddo.database_type = :csv
        end

        it "creates a new value for each row's column" do
          header = "col1\n"
          row1 = "r1c1\n"
          row2 = "r2c1\n"
          string = header + row1 + row2

          input = StringIO.new(string)
          output = StringIO.new
          @ddo.obfuscate(input, output)
          output.rewind

          header_out, row1_out, row2_out = output.read.split
          expect(header_out).to eq(header.strip)
          expect(row1_out).not_to match(/#{row1.strip}/)
          expect(row2_out).not_to match(/#{row2.strip}/)
          expect(row1_out.empty?).to be false
          expect(row2_out.empty?).to be false
        end

        it 'does not obfuscate unspecified columns' do
          header = "col1,col2\n"
          row1col1 = "r1c1"
          row1col2 = "r1c2"
          row2col1 = "r2c1"
          row2col2 = "r2c2"

          string = header + "#{row1col1},#{row1col2}\n" + "#{row2col1},#{row2col2}\n"

          input = StringIO.new(string)
          output = StringIO.new
          @ddo.obfuscate(input, output)
          output.rewind

          header_out, row1_out, row2_out = output.read.split
          expect(header_out).to eq(header.strip)

          [row1_out,row2_out].each_with_index do |row, i|
            ridx = i+1
            col1, col2 = row.split(',')
            expect(col1).not_to match(eval("row#{ridx}col1"))
            expect(col2).to eq(eval("row#{ridx}col2"))
          end
        end
      end

      context "when obfuscating a single column with matching enabled" do
        before do
          @ddo = MyObfuscate.new({
            csv: {
              "col1" => {:type => :string, :length => 8}
            },
            :column_mapper => {
              "col1" => "col1"
            }
          })
          @ddo.database_type = :csv
        end

        context
        it 'replaces all instances of the value in the column with the obfuscated value' do
          header = "col1\n"
          rows = %w(id1 id2 id1).join("\n")
          string = header + rows

          input = StringIO.new(string)
          output = StringIO.new
          @ddo.obfuscate(input, output)
          output.rewind

          header_out, *rows_out = output.read.split
          expect(rows_out.uniq.size).to eq(2)
        end
      end

      context "when obfuscating multiple columns with matching enabled" do
        before do
          @ddo = MyObfuscate.new({
            csv: {
              "col1" => {:type => :string, :length => 8},
            },
            :column_mapper => {
              "col1" => "col2"
            }
          })
          @ddo.database_type = :csv
        end

        it 'obfuscates the 2nd column when the source and target values are on the same row' do
          header = "col1,col2,col3\n"
          rows = %w(id1,id1,val1 id2,id2,val2 id3,id3,val3).join("\n")
          string = header + rows

          input = StringIO.new(string)
          output = StringIO.new
          @ddo.obfuscate(input, output)
          output.rewind

          header_out, *rows_out = output.read.split

          rows_out.each do |str|
            col1, col2 = str.split(',')
            expect(col1).to eq(col2)
          end
        end

        it 'obfuscates the 2nd column when the source and target values are on different rows' do
          header = "col1,col2,col3\n"
          rows = %w(id1,id1,val1 id2,id1,val2 id3,id1,val3).join("\n")
          string = header + rows

          input = StringIO.new(string)
          output = StringIO.new
          @ddo.obfuscate(input, output)
          output.rewind

          header_out, *rows_out = output.read.split

          new_col1, new_col2 = rows_out[0].split(',')
          rows_out.each do |str|
            col1, col2 = str.split(',')
            expect(new_col1).to eq(col2)
          end
        end
      end

    end
  end

end
