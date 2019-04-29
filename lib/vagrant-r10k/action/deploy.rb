require_relative 'base'

module VagrantPlugins
  module R10k
    module Action
      # run r10k deploy
      class Deploy < Base

        # determine if we should run, and get config
        def call(env)
          @logger.debug "vagrant::r10k::deploy called"

          unless r10k_enabled?(env)
            env[:ui].info "vagrant-r10k not configured; skipping"
            return @app.call(env)
          end

          unless provision_enabled?(env)
            env[:ui].info "provisioning disabled; skipping vagrant-r10k"
            return @app.call(env)
          end

          # get our config
          config = r10k_config(env)
          if config.nil?
            @logger.info "vagrant::r10k::deploy got nil configuration"
            raise ErrorWrapper.new(RuntimeError.new("vagrant-r10k configuration error; cannot continue"))
          end
          @logger.debug("vagrant::r10k::deploy: auto_deploy=#{config[:auto_deploy]}")
          @logger.debug("vagrant::r10k::deploy: env_dir_path=#{config[:env_dir_path]}")
          @logger.debug("vagrant::r10k::deploy: puppetfile_path=#{config[:puppetfile_path]}")
          @logger.debug("vagrant::r10k::deploy: module_path=#{config[:module_path]}")
          @logger.debug("vagrant::r10k::deploy: puppet_dir=#{config[:puppet_dir]}")

          env[:ui].info "vagrant-r10k: auto_deploy #{config[:auto_deploy]}"
          unless config[:auto_deploy]
            return @app.call(env)
          end

          deploy(env, config)

          @app.call(env)
        end
      end
    end
  end
end
