Puppet::Util::Log.newdesttype :syslog do
  def self.suitable?(obj)
    Puppet.features.syslog?
  end

  def close
    Syslog.close
  end

  def initialize
    Syslog.close if Syslog.opened?
    name = Puppet[:name]
    name = "puppet-#{name}" unless name =~ /puppet/

    options = Syslog::LOG_PID | Syslog::LOG_NDELAY

    # XXX This should really be configurable.
    str = Puppet[:syslogfacility]
    begin
      facility = Syslog.const_get("LOG_#{str.upcase}")
    rescue NameError
      raise Puppet::Error, "Invalid syslog facility #{str}"
    end

    @syslog = Syslog.open(name, options, facility)
  end

  def handle(msg)
    # XXX Syslog currently has a bug that makes it so you
    # cannot log a message with a '%' in it.  So, we get rid
    # of them.
    if msg.source == "Puppet"
      @syslog.send(msg.level, msg.to_s.gsub("%", '%%'))
    else
      @syslog.send(msg.level, "(%s) %s" % [msg.source.to_s.gsub("%", ""),
          msg.to_s.gsub("%", '%%')
        ]
      )
    end
  end
end

Puppet::Util::Log.newdesttype :file do
  require 'fileutils'

  def self.match?(obj)
    Puppet::Util.absolute_path?(obj)
  end

  def close
    if defined?(@file)
      @file.close
      @file = nil
    end
  end

  def flush
    @file.flush if defined?(@file)
  end

  attr_accessor :autoflush

  def initialize(path)
    @name = path
    # first make sure the directory exists
    # We can't just use 'Config.use' here, because they've
    # specified a "special" destination.
    unless FileTest.exist?(File.dirname(path))
      FileUtils.mkdir_p(File.dirname(path), :mode => 0755)
      Puppet.info "Creating log directory #{File.dirname(path)}"
    end

    # create the log file, if it doesn't already exist
    file = File.open(path, File::WRONLY|File::CREAT|File::APPEND)

    @file = file

    @autoflush = Puppet[:autoflush]
  end

  def handle(msg)
    @file.puts("#{msg.time} #{msg.source} (#{msg.level}): #{msg}")

    @file.flush if @autoflush
  end
end

Puppet::Util::Log.newdesttype :console do
  require 'puppet/util/colors'
  include Puppet::Util::Colors

  def initialize
    # Flush output immediately.
    $stdout.sync = true
  end

  def handle(msg)
    if msg.source == "Puppet"
      puts colorize(msg.level, "#{msg.level}: #{msg}")
    else
      puts colorize(msg.level, "#{msg.level}: #{msg.source}: #{msg}")
    end
  end
end

Puppet::Util::Log.newdesttype :telly_prototype_console do
  require 'puppet/util/colors'
  include Puppet::Util::Colors

  def initialize
    # Flush output immediately.
    $stderr.sync = true
    $stdout.sync = true
  end

  def handle(msg)
    error_levels = {
      :warning => 'Warning',
      :err     => 'Error',
      :alert   => 'Alert',
      :emerg   => 'Emergency',
      :crit    => 'Critical'
    }

    str = msg.respond_to?(:multiline) ? msg.multiline : msg.to_s

    case msg.level
    when *error_levels.keys
      $stderr.puts colorize(:hred, "#{error_levels[msg.level]}: #{str}")
    when :info
      $stdout.puts "#{colorize(:green, 'Info')}: #{str}"
    when :debug
      $stdout.puts "#{colorize(:cyan, 'Debug')}: #{str}"
    else
      $stdout.puts str
    end
  end
end

Puppet::Util::Log.newdesttype :host do
  def initialize(host)
    Puppet.info "Treating #{host} as a hostname"
    args = {}
    if host =~ /:(\d+)/
      args[:Port] = $1
      args[:Server] = host.sub(/:\d+/, '')
    else
      args[:Server] = host
    end

    @name = host

    @driver = Puppet::Network::Client::LogClient.new(args)
  end

  def handle(msg)
    unless msg.is_a?(String) or msg.remote
      @hostname ||= Facter["hostname"].value
      unless defined?(@domain)
        @domain = Facter["domain"].value
        @hostname += ".#{@domain}" if @domain
      end
      if Puppet::Util.absolute_path?(msg.source)
        msg.source = @hostname + ":#{msg.source}"
      elsif msg.source == "Puppet"
        msg.source = @hostname + " #{msg.source}"
      else
        msg.source = @hostname + " #{msg.source}"
      end
      begin
        #puts "would have sent #{msg}"
        #puts "would have sent %s" %
        #    CGI.escape(YAML.dump(msg))
        begin
          tmp = CGI.escape(YAML.dump(msg))
        rescue => detail
          puts "Could not dump: #{detail}"
          return
        end
        # Add the hostname to the source
        @driver.addlog(tmp)
      rescue => detail
        puts detail.backtrace if Puppet[:trace]
        Puppet.err detail
        Puppet::Util::Log.close(self)
      end
    end
  end
end

# Log to a transaction report.
Puppet::Util::Log.newdesttype :report do
  attr_reader :report

  match "Puppet::Transaction::Report"

  def initialize(report)
    @report = report
  end

  def handle(msg)
    @report << msg
  end
end

# Log to an array, just for testing.
module Puppet::Test
  class LogCollector
    def initialize(logs)
      @logs = logs
    end

    def <<(value)
      @logs << value
    end
  end
end

Puppet::Util::Log.newdesttype :array do
  match "Puppet::Test::LogCollector"

  def initialize(messages)
    @messages = messages
  end

  def handle(msg)
    @messages << msg
  end
end

Puppet::Util::Log.newdesttype :eventlog do
  def self.suitable?(obj)
    Puppet.features.eventlog?
  end

  def initialize
    @eventlog = Win32::EventLog.open("Application")
  end

  def to_native(level)
    case level
    when :debug,:info,:notice
      [Win32::EventLog::INFO, 0x01]
    when :warning
      [Win32::EventLog::WARN, 0x02]
    when :err,:alert,:emerg,:crit
      [Win32::EventLog::ERROR, 0x03]
    end
  end

  def handle(msg)
    native_type, native_id = to_native(msg.level)

    @eventlog.report_event(
      :source      => "Puppet",
      :event_type  => native_type,
      :event_id    => native_id,
      :data        => (msg.source and msg.source != 'Puppet' ? "#{msg.source}: " : '') + msg.to_s
    )
  end

  def close
    if @eventlog
      @eventlog.close
      @eventlog = nil
    end
  end
end
