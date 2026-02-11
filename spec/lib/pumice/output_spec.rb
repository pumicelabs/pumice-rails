# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Pumice::Output do
  let(:io) { StringIO.new }
  let(:output) { described_class.new(io: io) }

  def written
    io.string
  end

  describe '#header' do
    it 'writes title with divider' do
      output.header('Test Title')

      expect(written).to include('Test Title')
      expect(written).to include('=' * 80)
    end

    it 'includes emoji when graphical mode enabled' do
      output.header('Test', emoji: '>')

      expect(written).to start_with("\n> Test")
    end
  end

  describe '#line' do
    it 'writes text with newline' do
      output.line('Hello world')

      expect(written).to eq("Hello world\n")
    end

    it 'includes emoji when provided' do
      output.line('Test', emoji: '*')

      expect(written).to eq("* Test\n")
    end
  end

  describe '#blank' do
    it 'writes empty line' do
      output.blank

      expect(written).to eq("\n")
    end
  end

  describe '#divider' do
    it 'writes 80 equals by default' do
      output.divider

      expect(written).to eq("#{'=' * 80}\n")
    end

    it 'accepts custom length' do
      output.divider(40)

      expect(written).to eq("#{'=' * 40}\n")
    end
  end

  describe '#table_row' do
    it 'formats label and value in columns' do
      output.table_row('Label', 'Value')

      expect(written).to include('Label')
      expect(written).to include('Value')
      expect(written).to include('|')
    end

    it 'pads label to specified width' do
      output.table_row('Short', '123', label_width: 20)

      # Label should be left-justified to 20 chars
      expect(written).to match(/Short\s{15,}/)
    end
  end

  describe '#list_item' do
    it 'formats as indented label: value' do
      output.list_item('Name', 'John')

      expect(written).to include('Name')
      expect(written).to include(': John')
    end
  end

  describe '#success' do
    it 'prefixes with checkmark emoji' do
      output.success('Done')

      expect(written).to include('Done')
    end
  end

  describe '#error' do
    it 'prefixes with X emoji' do
      output.error('Failed')

      expect(written).to include('Failed')
    end
  end

  describe '#warning' do
    it 'prefixes with warning emoji' do
      output.warning('Caution')

      expect(written).to include('Caution')
    end
  end

  describe '#check' do
    it 'prefixes with checkmark' do
      output.check('Verified')

      expect(written).to include('Verified')
    end
  end

  describe '#bullet' do
    it 'formats as bullet point' do
      output.bullet('Item')

      expect(written).to eq("  \u2022 Item\n")
    end
  end

  describe '#prompt' do
    it 'writes without newline' do
      output.prompt('Enter: ')

      expect(written).to eq('Enter: ')
    end
  end

  describe '#human_size' do
    it 'returns 0 Bytes for zero' do
      expect(output.human_size(0)).to eq('0 Bytes')
    end

    it 'returns 0 Bytes for nil' do
      expect(output.human_size(nil)).to eq('0 Bytes')
    end

    it 'formats bytes' do
      expect(output.human_size(500)).to eq('500.00 Bytes')
    end

    it 'formats kilobytes' do
      expect(output.human_size(1536)).to eq('1.50 KB')
    end

    it 'formats megabytes' do
      expect(output.human_size(1_572_864)).to eq('1.50 MB')
    end

    it 'formats gigabytes' do
      expect(output.human_size(1_610_612_736)).to eq('1.50 GB')
    end
  end

  describe '#with_delimiter' do
    it 'adds commas to large numbers' do
      expect(output.with_delimiter(1_000_000)).to eq('1,000,000')
    end

    it 'handles small numbers' do
      expect(output.with_delimiter(999)).to eq('999')
    end

    it 'handles zero' do
      expect(output.with_delimiter(0)).to eq('0')
    end
  end

  describe 'graphical mode' do
    context 'when disabled' do
      let(:output) { described_class.new(io: io, graphical: false) }

      it 'omits emoji from line output' do
        output.line('Test', emoji: '*')

        expect(written).to eq("Test\n")
      end

      it 'omits emoji from header output' do
        output.header('Title', emoji: '>')

        expect(written).not_to include('>')
      end
    end

    context 'when enabled' do
      let(:output) { described_class.new(io: io, graphical: true) }

      it 'includes emoji in line output' do
        output.line('Test', emoji: '*')

        expect(written).to eq("* Test\n")
      end
    end
  end
end
