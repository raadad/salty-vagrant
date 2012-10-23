module VagrantSalt
  class Provisioner < Vagrant::Provisioners::Base
    class Config < Vagrant::Config::Base
      attr_accessor :minion_config
      attr_accessor :minion_key
      attr_accessor :minion_pub
      attr_accessor :master
      attr_accessor :run_highstate
      attr_accessor :salt_nfs_shared_folders
      attr_accessor :salt_file_root_path
      attr_accessor :salt_file_root_guest_path
      attr_accessor :salt_pillar_root_path
      attr_accessor :salt_pillar_root_guest_path
      attr_accessor :salt_install_type
      attr_accessor :salt_install_args

      def minion_config; @minion_config || "salt/minion.conf"; end
      def minion_key; @minion_key || false; end
      def minion_pub; @minion_pub || false; end
      def master; @master || false; end
      def run_highstate; @run_highstate || false; end
      def salt_nfs_shared_folders; @salt_nfs_shared_folders || false; end
      def salt_file_root_path; @salt_file_root_path || "salt/roots/salt"; end
      def salt_file_root_guest_path; @salt_file_root_guest_path || "/srv/salt"; end
      def salt_pillar_root_path; @salt_pillar_root_path || "salt/roots/pillar"; end
      def salt_pillar_root_guest_path; @salt_pillar_root_guest_path || "/srv/pillar"; end
      def salt_install_type; @salt_install_type || ''; end
      def salt_install_args; @salt_install_args || ''; end


      def expanded_path(root_path, rel_path)
        Pathname.new(rel_path).expand_path(root_path)
      end

      def bootstrap_options
        '%s %s' % [salt_install_type, salt_install_args]
      end
    end

    def self.config_class
      Config
    end

    def prepare
      # Calculate the paths we're going to use based on the environment
      @expanded_minion_config_path = config.expanded_path(env[:root_path], config.minion_config)
      if !config.master
        env[:ui].info "Adding state tree folders."
        @expanded_salt_file_root_path = config.expanded_path(env[:root_path], config.salt_file_root_path)
        @expanded_salt_pillar_root_path = config.expanded_path(env[:root_path], config.salt_pillar_root_path)
        check_salt_file_root_path
        check_salt_pillar_root_path
        share_salt_file_root_path
        share_salt_pillar_root_path
      end

      if config.minion_key
        @expanded_minion_key_path = config.expanded_path(env[:root_path], config.minion_key)
        @expanded_minion_pub_path = config.expanded_path(env[:root_path], config.minion_pub)
      end
    end

    def check_salt_file_root_path
      if !File.directory?(@expanded_salt_file_root_path)
        raise "Salt file root path does not exist: #{@expanded_salt_file_root_path}"
      end
    end

    def check_salt_pillar_root_path
      if !File.directory?(@expanded_salt_pillar_root_path)
        raise "Salt pillar root path does not exist: #{@expanded_salt_pillar_root_path}"
      end
    end

    def share_salt_file_root_path
      env[:ui].info "Sharing file root folder."
      env[:vm].config.vm.share_folder(
        "salt_file_root",
        config.salt_file_root_guest_path,
        @expanded_salt_file_root_path,
        :nfs => config.salt_nfs_shared_folders
      )
    end

    def share_salt_pillar_root_path
      env[:ui].info "Sharing pillar root path."
      env[:vm].config.vm.share_folder(
        "salt_pillar_root",
        config.salt_pillar_root_guest_path,
        @expanded_salt_pillar_root_path,
        :nfs => config.salt_nfs_shared_folders
      )
    end

    def salt_exists
      env[:ui].info "Checking for salt binaries..."
      if env[:vm].channel.test("which salt-call") and
         env[:vm].channel.test("which salt-minion")
        return true
      end
      env[:ui].info "Salt binaries not found."
      return false
    end

    def bootstrap_salt_minion
      env[:ui].info "Bootstrapping salt-minion on VM..."
      @expanded_bootstrap_script_path = config.expanded_path(__FILE__, "../../../scripts/bootstrap-salt-minion.sh")
      env[:vm].channel.upload(@expanded_bootstrap_script_path.to_s, "/tmp/bootstrap-salt-minion.sh")
      env[:vm].channel.sudo("chmod +x /tmp/bootstrap-salt-minion.sh")
      bootstrap = env[:vm].channel.sudo("/tmp/bootstrap-salt-minion.sh %s" % config.bootstrap_options) do |type, data|
        if data[0] == "\n"
          # Remove any leading newline but not whitespace. If we wanted to
          # remove newlines and whitespace we would have used data.lstrip
          data = data[1..-1]
        end
        env[:ui].info(data.rstrip)
      end
      if !bootstrap
        raise "Failed to bootstrap salt-minion on VM, see /var/log/bootstrap-salt-minion.log on VM."
      end
      env[:ui].info "Salt binaries installed on VM."
    end

    def accept_minion_key
      env[:ui].info "Accepting minion key."
      env[:vm].channel.sudo("salt-key -A")
    end

    def call_highstate
      if config.run_highstate
        env[:ui].info "Calling state.highstate"
        env[:vm].channel.sudo("salt-call saltutil.sync_all")
        env[:vm].channel.sudo("salt-call state.highstate") do |type, data|
          env[:ui].info(data)
        end
      else
        env[:ui].info "run_highstate set to false. Not running state.highstate."
      end
    end

    def upload_minion_config
      env[:ui].info "Copying salt minion config to vm."
      env[:vm].channel.upload(@expanded_minion_config_path.to_s, "/tmp/minion")
      env[:vm].channel.sudo("mv /tmp/minion /etc/salt/minion")
    end

    def upload_minion_keys
      env[:ui].info "Uploading minion key."
      env[:vm].channel.upload(@expanded_minion_key_path.to_s, "/tmp/minion.pem")
      env[:vm].channel.sudo("mv /tmp/minion.pem /etc/salt/pki/minion.pem")
      env[:vm].channel.upload(@expanded_minion_pub_path.to_s, "/tmp/minion.pub")
      env[:vm].channel.sudo("mv /tmp/minion.pub /etc/salt/pki/minion.pub")
    end

    def provision!

      if !config.master
        verify_shared_folders([config.salt_file_root_guest_path, config.salt_pillar_root_guest_path])
      end

      if !salt_exists
        bootstrap_salt_minion
      end

      if !config.master
        begin
          env[:vm].channel.sudo("mount|grep salt_")
        rescue
          env[:ui].warn(
            'Failed to mount the salt shares! Does the vagrant machine have ' \
            'Shared Folders support? If you have an NFS server around you '   \
            'can try setting "salt.salt_nfs_shared_folders = true" and use '  \
            '":nfs => true" on any shares you\'re trying to mount yourself.'
          )
        end
      end

      upload_minion_config

      if config.minion_key
        upload_minion_keys
      end

      call_highstate
    end

    def verify_shared_folders(folders)
      folders.each do |folder|
        # @logger.debug("Checking for shared folder: #{folder}")
        env[:ui].info "Checking shared folder #{folder}"
        if !env[:vm].channel.test("test -d #{folder}")
          raise "Missing folder #{folder}"
        end
      end
    end
  end
end

# vim: fenc=utf-8 spell spl=en cc=80 sts=2 sw=2 et
