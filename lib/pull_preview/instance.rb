require "erb"
require "ostruct"

module PullPreview
  class Instance
    attr_reader :admins
    attr_reader :cidrs
    attr_reader :compose_files
    attr_reader :default_port
    attr_reader :dns
    attr_reader :name
    attr_reader :subdomain
    attr_reader :ports
    attr_reader :registries
    attr_reader :ip_prefix
    attr_reader :swap_enabled
    alias swap_enabled? swap_enabled

    class << self
      attr_accessor :client
      attr_accessor :logger
    end

    class Provisioner
      COMPOSE_VERSION = "1.29.2".freeze

      class << self
        def ssh_access(ssh_public_keys)
          %{echo '#{ssh_public_keys.join("\n")}' > /home/ec2-user/.ssh/authorized_keys}
        end

        def prepare_user(remote_app_path)
          [
            "mkdir -p #{remote_app_path} && chown -R ec2-user.ec2-user #{remote_app_path}",
            "echo 'cd #{remote_app_path}' > /etc/profile.d/pullpreview.sh",
            "echo '[[ -f /etc/pullpreview/env ]] && set -o allexport; source /etc/pullpreview/env; set +o allexport' >> /etc/profile.d/pullpreview.sh"
          ]
        end

        def setup_swapping
          [
            "sudo sed -i '/^tmpfs/c\tmpfs       \/dev\/shm    tmpfs   defaults,size=256M  0   0' /etc/fstab",
            "echo 'vm.vfs_cache_pressure=50' | tee -a /etc/sysctl.conf"
          ]
        end

        def install_and_setup_docker
          [
            "yum install -y docker",
            %{curl -L "https://github.com/docker/compose/releases/download/#{COMPOSE_VERSION}/docker-compose-$(uname -s)-$(uname -m)" -o /usr/local/bin/docker-compose},
            "chmod +x /usr/local/bin/docker-compose",
            "usermod -aG docker ec2-user",
            "service docker start",
            "echo 'docker image prune -a --filter=\"until=96h\" --force' > /etc/cron.daily/docker-prune && chmod a+x /etc/cron.daily/docker-prune"
          ]
        end

        def finish_setup
          "mkdir -p /etc/pullpreview && touch /etc/pullpreview/ready && chown -R ec2-user:ec2-user /etc/pullpreview"
        end
      end
    end

    def self.normalize_name(name)
      name.
        gsub(/[^a-z0-9]/i, "-").
        squeeze("-")[0..60].
        gsub(/(^-|-$)/, "")
    end

    def initialize(name, opts = {})
      @name = self.class.normalize_name(name)
      @subdomain = opts[:subdomain] || name
      @admins = opts[:admins] || []
      @cidrs = opts[:cidrs] || ["0.0.0.0/0"]
      @default_port = opts[:default_port] || "80"
      # TODO: normalize
      @ports = (opts[:ports] || []).push(default_port).push("22").uniq.compact
      @compose_files = opts[:compose_files] || ["docker-compose.yml"]
      @registries = opts[:registries] || []
      @dns = opts[:dns]
      @ip_prefix = opts.key?(:ip_prefix) ? opts[:ip_prefix] : nil
      @ssh_results = []
      @swap_enabled = !opts[:disable_swap]
    end

    def remote_app_path
      REMOTE_APP_PATH
    end

    def ssh_public_keys
      @ssh_public_keys ||= admins.map do |github_username|
        URI.open("https://github.com/#{github_username}.keys").read.split("\n")
      end.flatten.reject{|key| key.empty?}
    end

    def success?
      @ssh_results.map(&:last).all?
    end

    def running?
      resp = client.get_instance_state(instance_name: name)
      resp.state.name == "running"
    rescue Aws::Lightsail::Errors::NotFoundException
      @instance_details = nil
      false
    end

    def ssh_ready?
      ssh("test -f /etc/pullpreview/ready")
    end

    def launch(az, bundle_id, blueprint_id, tags = {})
      logger.debug "Instance launching ssh_public_keys=#{ssh_public_keys.inspect}"

      params = {
        instance_names: [name],
        availability_zone: az,
        bundle_id: bundle_id,
        tags: {stack: STACK_NAME}.merge(tags).map{|(k,v)| {key: k.to_s, value: v.to_s}},
      }

      if latest_snapshot
        logger.info "Found snapshot to restore from: #{latest_snapshot.name}"
        logger.info "Creating new instance name=#{name}..."
        client.create_instances_from_snapshot(params.merge(
          user_data: init_from_snapshot_command,
          instance_snapshot_name: latest_snapshot.name
        ))
      else
        logger.info "Creating new instance name=#{name}..."
        client.create_instances(params.merge(
          user_data: setup_command,
          blueprint_id: blueprint_id
        ))
      end
    end

    def init_from_snapshot_command
      [
        "service docker restart"
      ].join(" && ")
    end

    def setup_command
      [
        Provisioner.ssh_access(ssh_public_keys),
        Provisioner.prepare_user(REMOTE_APP_PATH),
        swap_enabled? ? Provisioner.setup_swapping : nil,
        Provisioner.install_and_setup_docker,
        Provisioner.finish_setup
      ].flatten.reject(&:empty?).join(" && ")
    end

    def latest_snapshot
      @latest_snapshot ||= client.get_instance_snapshots.instance_snapshots.sort{|a,b| b.created_at <=> a.created_at}.find do |snap|
        snap.state == "available" && (snap.name == snapshot_name || snap.from_instance_name == name)
      end
    end

    def destroy!
      operation = client.delete_instance(instance_name: name).operations.first
      if operation.error_code.nil?
        PullPreview.logger.info "Instance successfully destroyed"
      else
        raise Error, "An error occurred while destroying the instance: #{operation.error_code} (#{operation.error_details})"
      end
    end

    def erb_locals
      OpenStruct.new(
        remote_app_path: remote_app_path,
        compose_files: compose_files,
        public_ip: public_ip,
        public_dns: public_dns,
        admins: admins,
        url: url,
        custom_launch_command: custom_launch_command,
        custom_env_vars: custom_env_vars
      )
    end

    def basic_auth
      ENV.fetch("BASIC_AUTH", nil)
    end

    def custom_launch_command
      ENV.fetch("PULLPREVIEW_LAUNCH_COMMAND", "")
    end

    def custom_env_vars
      ENV.fetch("PULLPREVIEW_ENV_VARS", "")
    end

    def snapshot_name
      ENV.fetch("PULLPREVIEW_SNAPSHOT_NAME", "")
    end

    def github_token
      ENV.fetch("GITHUB_TOKEN", "")
    end

    def github_repository_owner
      ENV.fetch("GITHUB_REPOSITORY_OWNER", "")
    end

    def update_script
      PullPreview.data_dir.join("update_script.sh.erb")
    end

    def update_script_rendered
      ERB.new(File.read(update_script)).result_with_hash(locals: erb_locals)
    end

    def setup_ssh_access
      File.open("/tmp/authorized_keys", "w+") do |f|
        f.write ssh_public_keys.join("\n")
      end
      scp("/tmp/authorized_keys", "/home/ec2-user/.ssh/authorized_keys", mode: "0600")
    end

    def setup_update_script
      tmpfile = Tempfile.new("update_script").tap do |f|
        f.write update_script_rendered
      end
      tmpfile.flush
      unless scp(tmpfile.path, "/tmp/update_script.sh", mode: "0755")
        raise Error, "Unable to copy the update script on instance. Aborting."
      end
    end

    def setup_prepost_scripts
      tmpfile = Tempfile.new(["prescript", ".sh"])
      tmpfile.puts "#!/bin/bash -e"
      registries.each_with_index do |registry, index|
        begin
          uri = URI.parse(registry)
          raise Error, "Invalid registry" if uri.host.nil? || uri.scheme != "docker"
          username = uri.user
          password = uri.password
          if password.nil?
            password = username
            username = "doesnotmatter"
          end
          tmpfile.puts 'echo "Logging into %{host}..."' % { host: uri.host }
          # https://docs.github.com/en/packages/guides/using-github-packages-with-github-actions#upgrading-a-workflow-that-accesses-ghcrio
          tmpfile.puts 'echo "%{password}" | docker login %{host} -u "%{username}" --password-stdin' % {
            host: uri.host.end_with?('docker.io') ? nil : '"' + uri.host + '"',
            username: username,
            password: password,
          }
        rescue URI::Error, Error => e
          logger.warn "Registry ##{index} is invalid: #{e.message}"
        end
      end
      tmpfile.flush
      unless scp(tmpfile.path, "/tmp/pre_script.sh", mode: "0755")
        raise Error, "Unable to copy the pre script on instance. Aborting."
      end
    end

    def wait_until_running!
      if wait_until { logger.info "Waiting for instance to be running" ; running? }
        logger.info "Instance is running public_ip=#{public_ip} public_dns=#{public_dns}"
      else
        logger.error "Timeout while waiting for instance running"
        raise Error, "Instance still not running. Aborting."
      end
    end

    def wait_until_ssh_ready!
      if wait_until { logger.info "Waiting for ssh" ; ssh_ready? }
        logger.info "Instance ssh access OK"
      else
        logger.error "Instance ssh access KO"
        raise Error, "Can't connect to instance over SSH. Aborting."
      end
    end

    def wait_until(max_retries = 30, interval = 5, &block)
      result = true
      retries = 0
      until block.call
        retries += 1
        if retries >= max_retries
          result = false
          break
        end
        sleep interval
      end
      result 
    end

    def open_ports
      client.put_instance_public_ports({
        port_infos: ports.map do |port_definition|
          port_range, protocol = port_definition.split("/", 2)
          protocol ||= "tcp"
          port_range_start, port_range_end = port_range.split("-", 2)
          port_range_end ||= port_range_start
          cidrs_to_use = cidrs
          if port_range_start.to_i == 22
            # allow SSH from anywhere
            cidrs_to_use = ["0.0.0.0/0"]
          end
          {
            from_port: port_range_start.to_i,
            to_port: port_range_end.to_i,
            protocol: protocol, # accepts tcp, all, udp
            cidrs: cidrs_to_use,
          }
        end,
        instance_name: name
      })
    end

    def scp(source, target, mode: "0644")
      ssh("cat - > #{target} && chmod #{mode} #{target}", input: File.new(source))
    end

    def ssh(command, input: nil)
      key_file_path = "/tmp/tempkey"
      cert_key_path = "/tmp/tempkey-cert.pub"
      File.open(key_file_path, "w+") do |f|
        f.puts access_details.private_key
      end
      File.open(cert_key_path, "w+") do |f|
        f.puts access_details.cert_key
      end
      [key_file_path].each{|file| FileUtils.chmod 0600, file}

      cmd = "ssh #{"-v " if logger.level == Logger::DEBUG}-o ServerAliveInterval=15 -o IdentitiesOnly=yes -i #{key_file_path} #{ssh_address} #{ssh_options.join(" ")} '#{command}'"
      if input && input.respond_to?(:path)
        cmd = "cat #{input.path} | #{cmd}"
      end
      logger.debug cmd
      system(cmd).tap {|result| @ssh_results.push([cmd, result])}
    end

    def username
      access_details.username
    end

    def public_ip
      access_details.ip_address
    end

    def public_dns
      # https://community.letsencrypt.org/t/a-certificate-for-a-63-character-domain/78870/4
      remaining_chars_for_subdomain = 62 - dns.size - public_ip.size - (ip_prefix&.size || 0) - ("." * 3).size
      [
        [subdomain[0..remaining_chars_for_subdomain], ip_prefix, public_ip.gsub(".", "-")].compact.join("-"),
        dns
      ].join(".")
    end

    def url
      scheme = (default_port == "443" ? "https" : "http")
      "#{scheme}://#{basic_auth && basic_auth + '@'}#{public_dns}:#{default_port}"
    end

    def ssh_address
      [username, public_ip].compact.join("@")
    end

    def ssh_options
      [
        "-o StrictHostKeyChecking=no",
        "-o UserKnownHostsFile=/dev/null",
        "-o LogLevel=ERROR",
        "-o ConnectTimeout=10",
      ]
    end

    def instance_details
      @instance_details ||= client.get_instance(instance_name: name).instance
    end

    def access_details
      @access_details ||= client.get_instance_access_details({
        instance_name: name,
        protocol: "ssh", # accepts ssh, rdp
      }).access_details.tap do |details|
        logger.debug "access_details=#{details.inspect}"
      end
    end

    def client
      PullPreview.lightsail
    end

    def logger
      PullPreview.logger
    end
  end
end
