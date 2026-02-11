# frozen_string_literal: true

module Pumice
  class Output
    def initialize(io: $stdout, graphical: true)
      @io = io
      @graphical = graphical
    end

    def header(title, emoji: nil)
      @io.puts "\n#{prefix_emoji(emoji)}#{title}\n"
      @io.puts "=" * 80
    end

    def line(text, emoji: nil)
      @io.puts "#{prefix_emoji(emoji)}#{text}"
    end

    def blank
      @io.puts
    end

    def divider(length = 80)
      @io.puts "=" * length.to_i
    end

    def table_row(label, value, label_width: 35)
      @io.puts "#{label.ljust(label_width)} | #{value.rjust(10)}"
    end

    def list_item(label, value, label_width: 30, indent: 2)
      @io.puts "#{' ' * indent}#{label.ljust(label_width)}: #{value}"
    end

    def success(message)
      @io.puts "#{prefix_emoji('✅')}#{message}"
    end

    def error(message)
      @io.puts "#{prefix_emoji('❌')}#{message}"
    end

    def warning(message)
      @io.puts "#{prefix_emoji('⚠️')}#{message}"
    end

    def check(message)
      @io.puts "#{prefix_emoji('✓')}#{message}"
    end

    def bullet(message)
      @io.puts "  • #{message}"
    end

    def prompt(message)
      @io.print message
    end

    def human_size(bytes)
      return '0 Bytes' if bytes.to_i == 0

      k = 1024.0
      sizes = ['Bytes', 'KB', 'MB', 'GB', 'TB']
      i = (Math.log(bytes) / Math.log(k)).floor

      format('%.2f %s', bytes / k**i, sizes[i])
    end

    def with_delimiter(number)
      number.to_s.reverse.gsub(/(\d{3})(?=\d)/, '\\1,').reverse
    end

    def prefix_emoji(emoji)
      if @graphical && !emoji.nil?
        "#{emoji} "
      else
        ''
      end
    end
  end
end
