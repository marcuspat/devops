console_tables = ["delayed_job_failures",
                  "delayed_jobs",
                  "node_classes",
                  "node_group_edges",
                  "node_groups",
                  "nodes",
                  "node_class_memberships",
                  "node_group_class_memberships",
                  "node_group_memberships",
                  "reports",
                  "metrics",
                  "parameters",
                  "report_logs",
                  "resource_statuses",
                  "resource_events",
                  "timeline_events"]

auth_tables = ["activations",
               "users",
               "authorized_users",
               "roles",
               "authorized_users_roles"]

require 'tmpdir'

def prepare_transfer_scripts(dir, src_dbname, src_username, src_host, src_port, tables)
  conn = ActiveRecord::Base.connection

  pre_path = ""
  post_path = ""

  File.open(File.join(dir, ".pre_transfer"), File::CREAT|File::TRUNC|File::RDWR, 0600) do |file|
    pre_path = file.path

    #Set ON_ERROR_STOP
    file.write("\\set ON_ERROR_STOP\n")

    #Set environment
    file.write("SET client_encoding = 'utf8';\n")
    file.write("SET client_min_messages = warning;\n")
 
    #Start a transaction
    file.write("BEGIN WORK;\n")

    #Drop all constraints
    get_drop_constraint_statements(conn, tables).each do |stmt|
      file.write(stmt)
    end
  end

  File.open(File.join(dir, ".post_transfer"), File::CREAT|File::TRUNC|File::RDWR, 0600) do |file|
    post_path = file.path

    #Restore all constraints
    get_restore_constraint_statements(conn, tables).each do |stmt|
      file.write(stmt)
    end

    #Commit transaction
    file.write("COMMIT WORK;\n")
  end

  File.open(File.join(dir, ".transfer"), File::CREAT|File::TRUNC|File::RDWR, 0700) do |file|

    file.write("\#/bin/bash\n");
    file.write("set -e\n");
    file.write("cat #{pre_path}\n");

    tables.each do |table|
      file.write("echo \"TRUNCATE #{table};\"\n")
      file.write("echo \"COPY #{table} FROM STDIN WITH NULL 'NULL';\"\n")
      file.write("mysql --defaults-file=" + File.join(dir, ".my.#{src_dbname}.cnf") + " --user=#{src_username} " +
             "--host=#{src_host} --port=#{src_port} " +
             "-B --column-names=false --quick=true --default-character-set=utf8 -e \"connect #{src_dbname}; set net_write_timeout=3600; select * from #{table};\"\n")
      file.write("echo '\\.'\n")

      # Inserting rows with specific ids causes the sequence associated with
      # the id column to get out of sync. To fix that, we figure out the
      # sequence (there's only one per table, and it must be the id column) and
      # set it to the highest id in the table.
      seq_results = conn.execute <<-SEQ_SELECT
      SELECT seq.relname
      FROM pg_class AS seq, pg_depend AS dep, pg_class AS tbl, pg_attribute AS c
      WHERE seq.relkind = 'S' AND seq.oid = dep.objid AND dep.refobjid = tbl.oid AND dep.refobjid = c.attrelid AND dep.refobjsubid = c.attnum
      AND tbl.relname = '#{table}'
      SEQ_SELECT

      if result = seq_results.first
        seq = result['relname']
        # 'true' here means we set the current value rather than the next value, so
        # the next value will be one greater than the current max.
        file.write("echo \"SELECT setval('#{seq}', MAX(id), true) FROM #{table};\"\n")
      end
    end

    file.write("cat #{post_path}\n");
  end

end

def run_transfer(dir)
  conn = ActiveRecord::Base.connection
  config = conn.instance_variable_get(:@config)

  export_err = File.join(dir, ".exporterr")
  import_err = File.join(dir, ".importerr")

  #Since MySQL exports carriage return characters in their literal form
  #but PostgreSQL expects them as an escaped character 'r' we need to
  #replace them accordingly on the fly.
  cr_fixer = "sed -e 's/\\r/\\\\r/g'"

  if(config[:host] == 'localhost') then
    #use domain sockets, pe-postgres and peer authentication - it should provide better performance
    system "(" + File.join(dir, ".transfer") + " || echo $? > #{export_err}) | #{cr_fixer} | (su - pe-postgres -s /bin/bash -c \"/opt/puppet/bin/psql #{config[:database]}\" || echo $? > #{import_err})"
  else
    #use tcp sockets and password authentication and send the password in a secure way (avoid using PGPASSWD environment variable)
    pgpassfile = File.join(dir, ".pgpass")
    File.open(pgpassfile, File::CREAT|File::TRUNC|File::RDWR, 0600) do |file|
      file.write("#{config[:host]}:#{config[:port]}:#{config[:database]}:#{config[:username]}:#{config[:password]}\n")
    end

    system "(" + File.join(dir, ".transfer") + " || echo $? > #{export_err}) | #{cr_fixer} | (PGPASSFILE=#{pgpassfile} /opt/puppet/bin/psql -U #{config[:username]} -h #{config[:host]} #{config[:database]} || echo $? > #{import_err})"
  end

  if(File.exists?(export_err) || File.exists?(import_err)) then
    puts "Database transfer failed."
    exit 1
  end
end

def get_drop_constraint_statements(conn, tables)
  drop_constraints_stmt =
    "SELECT 'ALTER TABLE \"' || t.relname || '\" DROP CONSTRAINT \"' || c.conname || '\";' AS stmt " +
    "FROM pg_constraint c JOIN pg_class t ON t.oid = c.conrelid WHERE t.relname IN (" +
    tables.map{ |table| "'" + table + "'" }.join(',') + ") " +
    "ORDER BY c.contype" #order by constraint type (f,p,u) so that foreign keys would be dropped as first

  drop_constraint_statements = []

  conn.execute(drop_constraints_stmt).each do |row|
    drop_constraint_statements << row['stmt'] + "\n"
  end

  drop_constraint_statements
end

def get_restore_constraint_statements(conn, tables)
  restore_constraints_stmt =
    "SELECT 'ALTER TABLE \"' || t.relname || '\" ADD CONSTRAINT \"' || c.conname || " +
    "'\" ' || pg_get_constraintdef(c.oid) || ';' AS stmt " +
    "FROM pg_constraint c JOIN pg_class t ON t.oid = c.conrelid WHERE t.relname IN (" +
    tables.map{ |table| "'" + table + "'" }.join(',') + ") " +
    "ORDER BY c.contype DESC" #order by constraint type desc (u,p,f) so that foreign keys would be restored as last

  restore_constraint_statements = []

  conn.execute(restore_constraints_stmt).each do |row|
    restore_constraint_statements << row['stmt'] + "\n"
  end

  restore_constraint_statements
end

def is_postgres?(conn)
  conn.instance_variable_get(:@config)[:adapter] == 'postgresql'
end

def is_pe_postgres?(conn)
  if is_postgres?(conn)
    conn.execute("SELECT COUNT(*) AS count FROM pg_database WHERE datname = 'pe-postgres'").first['count'] == '1'
  else
    false
  end
end

def get_free_space(file)
  header_available_last_char_index = -1
  last_line = nil
  avail = 'Available'
  %x(env LC_ALL=C_C.C df -k '#{file}').split("\n").each do |line|
    if header_available_last_char_index == -1 && line =~ /^Filesystem\s+1K-blocks\s+Used\s+#{avail}\s+Use%\s+Mounted on$/
      header_available_last_char_index = line.index(avail) + avail.length
    else
      last_line = line
    end
  end

  if header_available_last_char_index != -1 && !last_line.nil?
    return last_line.slice(0, header_available_last_char_index).split(' ').last.to_i / 1024
  end

  return -1
end

namespace :db do
  desc 'Create a temporary directory and print its full path to STDOUT'
  task :tmpdir do
    puts Dir.mktmpdir
  end

  namespace :console do
    desc 'Print current database name to STDOUT'
    task :current_database => :environment do
      puts ActiveRecord::Base.connection.current_database
    end

    desc 'Print current database user to STDOUT'
    task :current_user => :environment do
      conn = ActiveRecord::Base.connection
      config = conn.instance_variable_get(:@config)
      puts config[:username]
    end

    desc 'Print current database host to STDOUT'
    task :current_host => :environment do
      conn = ActiveRecord::Base.connection
      config = conn.instance_variable_get(:@config)
      puts config[:host].nil? ? 'localhost' : config[:host]
    end

    desc 'Print current database port to STDOUT'
    task :current_port => :environment do
      conn = ActiveRecord::Base.connection
      config = conn.instance_variable_get(:@config)
      puts config[:port].nil? ? '3306' : config[:port]
    end

    desc 'Print current largest table size (in MB) to STDOUT'
    task :current_largest_table_size => :environment do
      if is_pe_postgres?(ActiveRecord::Base.connection)
        largest_table_size = ActiveRecord::Base.connection.execute("SELECT MAX(pg_total_relation_size(tablename::varchar)) AS size FROM pg_tables WHERE schemaname = 'public'").first['size'].to_i / (1024*1024)
      else
        largest_table_size = -1 #unable to analyze the database
      end

      puts largest_table_size.to_s
    end

    desc 'Print free disk space for the tablespace (in MB) to STDOUT'
    task :current_tablespace_free => :environment do
      conn = ActiveRecord::Base.connection
      if is_pe_postgres?(ActiveRecord::Base.connection)
        db = conn.current_database

        datadir = %x(su - pe-postgres -s /bin/bash -c "/opt/puppet/bin/psql #{db} -Atc 'SHOW data_directory'").sub(/\n/, '')
        tablespace_oid = conn.execute("SELECT oid FROM pg_tablespace WHERE oid = (SELECT dattablespace FROM pg_database WHERE datname = '#{db}')").first['oid']
        tablespace_dir = "#{datadir}/pg_tblspc/#{tablespace_oid}"
        freespace = get_free_space(tablespace_dir)
      else
        freespace = -1 #unable to get the free space
      end

      puts freespace.to_s
    end

    desc 'Create a MySQL configuration file with current connection\'s password in TMPDIR'
    task :store_source_password => :environment do
      dir = ENV['TMPDIR']
      conn = ActiveRecord::Base.connection
      config = conn.instance_variable_get(:@config)
      File.open(File.join(dir, ".my.#{config[:database]}.cnf"), File::CREAT|File::TRUNC|File::RDWR, 0600) do |file|
        file.write("[client]\n")
        file.write("password='#{config[:password]}'")
      end
    end

    desc 'Transfer data from MySQL to PostgreSQL'
    task :transfer => :environment do
      src_dbname = ENV['SRC_DBNAME']
      src_username = ENV['SRC_USERNAME']
      src_host = ENV['SRC_HOST']
      src_port = ENV['SRC_PORT']
      dir = ENV['TMPDIR']
      prepare_transfer_scripts(dir, src_dbname, src_username, src_host, src_port, console_tables)
      run_transfer(dir)
      FileUtils.rm_rf(dir)
    end
  end
end
