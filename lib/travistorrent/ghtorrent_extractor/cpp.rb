#
# (c) 2025 Minh Thien Luu
#

require_relative 'comment_stripper'

# Supported testing frameworks: Google Test, Catch2
module CppData
  include CommentStripper

  def src_file_filter
    lambda do |f|
      path = if f.class == Hash then f[:path] else f end
      path.match?(/\.(cpp|cxx|cc|h|hpp)$/) && !test_file_filter.call(f)
    end
  end

  def test_file_filter
    lambda do |f|
      path = if f.class == Hash then f[:path] else f end
      path.match?(/\.(cpp|cxx|cc)$/) &&
        (path.match?(/\.(test|spec)\.(cpp|cxx|cc)$/) ||
         path.match?(/tests?\//i) ||
         path.match?(/test_.*\.(cpp|cxx|cc)$/i))
    end
  end

  def test_case_filter
    lambda do |l|
      # Google Test: TEST, TEST_F
      # Catch2: TEST_CASE
      !l.match(/^\s*(TEST|TEST_F|TEST_CASE)\s*\(/).nil?
    end
  end

  def assertion_filter
    lambda do |l|
      # Google Test: ASSERT_*, EXPECT_*
      # Catch2: REQUIRE, CHECK
      !l.match(/(ASSERT|EXPECT)_(TRUE|FALSE|EQ|NE|LT|GT|LE|GE|STREQ|STRNE)\s*\(/).nil? ||
        !l.match(/(REQUIRE|CHECK)\s*\(/).nil?
    end
  end

  def strip_comments(buff)
    strip_c_style_comments(buff)
  end
end