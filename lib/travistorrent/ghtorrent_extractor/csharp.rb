#
# (c) 2025 Minh Thien Luu
#

require_relative 'comment_stripper'

# Supported testing frameworks: MSTest, NUnit, xUnit
module CSharpData
  include CommentStripper

  def src_file_filter
    lambda do |f|
      path = if f.class == Hash then f[:path] else f end
      path.end_with?('.cs') && !test_file_filter.call(f)
    end
  end

  def test_file_filter
    lambda do |f|
      path = if f.class == Hash then f[:path] else f end
      path.end_with?('.cs') &&
        (path.match?(/\.(test|spec)\.cs$/) ||
         path.match?(/tests?\//i) ||
         path.match?(/test_.*\.cs$/i))
    end
  end

  def test_case_filter
    lambda do |l|
      # MSTest: [TestMethod]
      # NUnit: [Test]
      # xUnit: [Fact], [Theory]
      !l.match(/^\s*\[(TestMethod|Test|Fact|Theory)\]/).nil?
    end
  end

  def assertion_filter
    lambda do |l|
      # MSTest/NUnit: Assert.*
      # xUnit: Assert.*
      !l.match(/Assert\./).nil?
    end
  end

  def strip_comments(buff)
    strip_c_style_comments(buff)
  end
end