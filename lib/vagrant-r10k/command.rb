require 'optparse'

module VagrantPlugins
  module R10k
    class Command < Vagrant.plugin('2', :command)
      include VagrantPlugins::R10k::Helpers

      def self.synopsis
        'run r10k'
      end

      def execute
        options = {}

        opts = OptionParser.new do |o|
          o.banner = "Usage: vagrant r10k [options] [name|id]"
          o.separator ""
          o.separator "Options:"
          o.separator ""

          o.on("--host NAME", "Name the host for the config") do |h|
            options[:host] = h
          end
        end

        argv = parse_options(opts)
        return if !argv

        config_done = []
        with_target_vms(argv) do |machine|
          env = {}
          env[:machine] = machine
          env[:root_path] = machine.env.root_path
          env[:ui] = machine.env.ui
          config = r10k_config(env)

          next if config.nil?
          next if config_done.include? config

          deploy(env, config)

          config_done << config
        end
      end
    end
  end
end
