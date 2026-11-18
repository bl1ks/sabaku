# frozen_string_literal: true

require "minitest/autorun"
require "binary_message"

class BinaryMessageTest < Minitest::Test
  def test_value
    # Active Support's transliterate raises with an ASCII-8BIT message holding a
    # GB18030 byte. The child has to survive serializing it.
    raise Encoding::ConverterNotFoundError, "\xA9".b if BinaryMessage.value.zero?

    assert_equal 1, BinaryMessage.value
  end
end
