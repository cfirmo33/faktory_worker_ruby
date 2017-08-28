require 'socket'
require 'json'
require 'uri'
require 'securerandom'

module Faktory
  class CommandError < StandardError;end
  class ParseError < StandardError;end

  class Client
    @@random_process_wid = SecureRandom.hex(8)

    attr_accessor :middleware

    # Best practice is to rely on the localhost default for development
    # and configure the environment variables for non-development environments.
    #
    # FAKTORY_PROVIDER=MY_FAKTORY_URL
    # MY_FAKTORY_URL=tcp://:somepass@my-server.example.com:7419
    #
    # Note above, the URL can contain the password for secure installations.
    def initialize(url: 'tcp://localhost:7419', debug: false)
      @debug = debug
      @middleware = Faktory.client_middleware.dup
      @location = uri_from_env || URI(url)
      open
    end

    def close
      return unless @sock
      command "END"
      @sock.close
      @sock = nil
    end

    def push(job)
      transaction do
        command "PUSH", JSON.generate(job)
        ok!
      end
    end

    def pop(*queues)
      job = nil
      transaction do
        command("POP", *queues)
        job = result
      end
      JSON.parse(job) if job
    end

    def ack(jid)
      transaction do
        command("ACK", jid)
        ok!
      end
    end

    def fail(jid, ex)
      transaction do
        command("FAIL", jid, JSON.dump({ message: ex.message[0...1000],
                          errtype: ex.class.name,
                          backtrace: ex.backtrace}))
        ok!
      end
    end

    # Sends a heartbeat to the server, in order to prove this
    # worker process is still alive.
    #
    # Return a string signal to process, legal values are "quiet" or "terminate".
    # The quiet signal is informative: the server won't allow this process to POP
    # any more jobs anyways.
    def beat
      transaction do
        command("BEAT", JSON.dump("wid": @@random_process_wid))
        str = result
        if str == "OK"
          str
        else
          hash = JSON.parse(str)
          hash["signal"]
        end
      end
    end

    private

    def debug(line)
      puts line
    end

    def open
      @sock = TCPSocket.new(@location.hostname, @location.port)
      @sock.setsockopt(Socket::SOL_SOCKET, Socket::SO_KEEPALIVE, true)

      payload = {
        "wid": @@random_process_wid,
        "hostname": Socket.gethostname,
        "pid": $$,
        "labels": ["ruby-#{RUBY_VERSION}"],
      }
      payload["password"] = @location.password if @location.password

      command("AHOY", JSON.dump(payload))
      ok!
    end

    def command(*args)
      cmd = args.join(" ")
      @sock.puts(cmd)
      debug "> #{cmd}" if @debug
    end

    def transaction
      retryable = true
      begin
        yield
      rescue Errno::EPIPE, Errno::ECONNRESET
        if retryable
          retryable = false
          open
          retry
        else
          raise
        end
      end
    end

    def result
      line = @sock.gets
      debug "< #{line}" if @debug
      chr = line[0]
      if chr == '+'
        line[1..-1].strip
      elsif chr == '$'
        count = line[1..-1].strip.to_i
        data = nil
        data = @sock.read(count) if count > 0
        line = @sock.gets
        data
      elsif chr == '-'
        raise CommandError, line[1..-1]
      else
        # this is bad, indicates we need to reset the socket
        # and start fresh
        raise ParseError, line.strip
      end
    end

    def ok!
      resp = result
      raise CommandError, resp if resp != "OK"
      true
    end

    # FAKTORY_PROVIDER=MY_FAKTORY_URL
    # MY_FAKTORY_URL=tcp://:some-pass@some-hostname:7419
    def uri_from_env
      prov = ENV['FAKTORY_PROVIDER']
      return nil unless prov
      raise(ArgumentError, <<-EOM) if prov.index(":")
Invalid FAKTORY_PROVIDER '#{prov}', it should be the name of the ENV variable that contains the URL
    FAKTORY_PROVIDER=MY_FAKTORY_URL
    MY_FAKTORY_URL=tcp://:some-pass@some-hostname:7419
EOM
      val = ENV[prov]
      return nil unless val
      URI(val)
    end

  end
end

