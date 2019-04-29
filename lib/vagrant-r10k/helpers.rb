require 'r10k/logging'
require 'log4r'

# this is an ugly monkeypatch, since we're running inside of Vagrant,
# which has already defined logger but not with the debug1 and debug2 custom levels
module Log4r
  # this is an ugly monkeypatch, since we're running inside of Vagrant,
  # which has already defined logger but not with the debug1 and debug2 custom levels
  class Logger

    def debug1(msg)
      self.debug(msg)
    end

    def debug2(msg)
      self.debug(msg)
    end
  end
end

# patch this so we can get programmatic access to the errors
module R10K
  # patch this so we can get programmatic access to the errors
  class TaskRunner
    def get_errors
      @errors
    end
  end
end

module VagrantPlugins
  module R10k
    # General-use vagrant-r10k helper methosd
    module Helpers

      # run the actual r10k deploy
      def deploy(env, config)
        @logger.debug("vagrant::r10k::deploy.deploy called")
        require 'r10k/task_runner'
        require 'r10k/task/puppetfile'

        env[:ui].info "vagrant-r10k: Beginning r10k deploy of puppet modules into #{config[:module_path]} using #{config[:puppetfile_path]}"

        if ENV["VAGRANT_LOG"] == "debug"
          R10K::Logging.level = 'debug'
        else
          R10K::Logging.level = 'info'
        end

        unless File.file?(config[:puppetfile_path])
          raise ErrorWrapper.new(RuntimeError.new("Puppetfile at #{config[:puppetfile_path]} does not exist."))
        end

        # do the actual module buildout
        runner = R10K::TaskRunner.new([])
        begin
          puppetfile = get_puppetfile(config)
          @logger.debug("vagrant-r10k: creating Puppetfile::Sync task")
          task   = R10K::Task::Puppetfile::Sync.new(puppetfile)
          @logger.debug("vagrant-r10k: appending task to runner queue")
          runner.append_task task
          @logger.debug("vagrant-r10k: running sync task")
          runner.run
          @logger.debug("vagrant-r10k: sync task complete")
        rescue Exception => ex
          env[:ui].error "Invalid syntax in Puppetfile at #{config[:puppetfile_path]}"
          raise ErrorWrapper.new(ex.original)
        end
        unless runner.succeeded?
          runner.get_errors().each do |error|
            if error[1].message.include?("fatal: unable to access") and error[1].message.include?("Could not resolve host")
              # if we can't resolve the host, the error should include how to skip provisioning
              @logger.debug("vagrant-r10k: caught 'Could not resolve host' error")
              raise ErrorWrapper.new(RuntimeError.new(error[1].message + "\n\nIf you don't have connectivity to the host, running 'vagrant up --no-provision' will skip r10k deploy and all provisioning."))
            else
              raise ErrorWrapper.new(RuntimeError.new(error[1]))
            end
          end
        end
        env[:ui].info "vagrant-r10k: Deploy finished"
        @app.call(env) if @app.respond_to? :call
      end

      # Determine if r10k.puppet_dir and r10k.puppetfile_path are in config
      #
      # @param [Vagrant::Environment] env
      #
      # @return [Boolean]
      def r10k_enabled?(env)
        unset = Vagrant::Plugin::V2::Config::UNSET_VALUE
        if env[:machine].config.r10k.puppet_dir == unset or env[:machine].config.r10k.puppetfile_path == unset
          return false
        end
        return true
      end

      # Determine if --no-provision was specified
      #
      # @param [Vagrant::Environment] env
      #
      # @return [Boolean]
      def provision_enabled?(env)
        env.fetch(:provision_enabled, true)
      end

      # Get the root directory for the environment
      #
      # @param [Vagrant::Environment] env
      #
      # @return [String]
      def env_dir(env)
        env[:root_path]
      end

      # Get the Puppetfile path from config
      #
      # @param [Vagrant::Environment] env
      #
      # @return [File]
      def puppetfile_path(env)
        File.join(env_dir(env), env[:machine].config.r10k.puppetfile_path)
      end

      # Get the Puppet provisioner from config
      #
      # @param [Vagrant::Environment] env
      #
      # @return something
      def puppet_provisioner(env)
        provider = nil
        env[:machine].config.vm.provisioners.each do |prov|
          if prov.respond_to?(:type)
            next if prov.type != :puppet
          else
            next if prov.name != :puppet
          end
          provider = prov
        end
        provider
      end

      # Get the r10k config
      #
      # @param [Vagrant::Environment] env
      #
      # @return [Hash]
      def r10k_config(env)
        ret = { :module_path => nil }
        ret[:auto_deploy] = env[:machine].config.r10k.auto_deploy
        ret[:env_dir_path] = env_dir(env)
        ret[:puppetfile_path] = puppetfile_path(env)
        prov = puppet_provisioner(env)
        return nil if prov.nil?
        ret[:module_path] = module_path(env, prov, ret[:env_dir_path])
        return nil if ret[:module_path].nil?
        ret[:puppet_dir] = File.join(ret[:env_dir_path], env[:machine].config.r10k.puppet_dir)
        ret
      end

      # Get the module path
      #
      # @param [Vagrant::Environment] env
      # @param [something] prov
      #
      # @return [File] or [nil]
      def module_path(env, prov, env_dir_path)
        unset = Vagrant::Plugin::V2::Config::UNSET_VALUE
        # if module_path has been set before, check if it fits to one defined in the provisioner config
        if env[:machine].config.r10k.module_path != unset
          module_path = env[:machine].config.r10k.module_path
          if prov.config.module_path.is_a?(Array) and ! prov.config.module_path.include?(module_path)
            raise ErrorWrapper.new(RuntimeError.new("vagrant-r10k: module_path \"#{module_path}\" is not within the ones defined in puppet provisioner; please correct this condition"))
          elsif prov.config.module_path.nil?
            env[:ui].info "vagrant-r10k: Puppet provisioner module_path is nil, assuming puppet4 environment mode"
          elsif ! prov.config.module_path.is_a?(Array) and prov.config.module_path != module_path
            raise ErrorWrapper.new(RuntimeError.new("vagrant-r10k: module_path \"#{module_path}\" is not the same as in puppet provisioner (#{prov.config.module_path}); please correct this condition"))
          end
        # no modulepath explict set in config, build one from the provisioner config
        else
          module_path = prov.config.module_path.is_a?(Array) ? prov.config.module_path[0] : prov.config.module_path
          # TODO - raise here instead of returning nil later
          env[:ui].info "vagrant-r10k: Building the r10k module path with puppet provisioner module_path \"#{module_path}\". (if module_path is an array, first element is used)"
        end

        return nil if module_path.nil?

        # now join the module_path with the env_dir to have an absolute path
        File.join(env_dir_path, module_path)
      end

      # Get a Puppetfile for the specified path
      #
      # @param [Hash] config
      #
      # @return [R10K::Puppetfile]
      def get_puppetfile(config)
        require 'r10k/puppetfile'
        R10K::Puppetfile.new(config[:puppet_dir], config[:module_path], config[:puppetfile_path])
      end

      # wrapper to create VagrantErrors
      class ErrorWrapper < ::Vagrant::Errors::VagrantError
        attr_reader :original

        def initialize(original)
          @original = original
        end

        def to_s
          "#{original.class}: #{original.to_s}"
        end

        private

        def method_missing(fun, *args, &block)
          original.send(fun, *args, &block)
        end

      end

    end
  end
end
