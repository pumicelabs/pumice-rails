# frozen_string_literal: true

require 'rails/generators/base'

module Pumice
  module Generators
    class InstallGenerator < Rails::Generators::Base
      source_root File.expand_path('templates', __dir__)

      desc 'Creates a Pumice initializer with default configuration'

      def create_initializer_file
        template 'initializer.rb.erb', 'config/initializers/pumice.rb'
      end

      def show_next_steps
        say ''
        say 'Pumice installed. Next steps:', :green
        say ''
        say '  1. Review config/initializers/pumice.rb'
        say '  2. Generate sanitizers for your models:'
        say ''
        say '     rails generate pumice:sanitizer User'
        say '     rails generate pumice:sanitizer Post'
        say ''
        say '  3. Run a dry run to preview:'
        say ''
        say '     rake db:scrub:test'
        say ''
      end
    end
  end
end
