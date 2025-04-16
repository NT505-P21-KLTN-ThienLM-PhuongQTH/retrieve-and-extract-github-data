#
# (c) 2025 Minh Thien Luu
#

require_relative 'comment_stripper'

# Supported testing frameworks: Jest, Mocha, Jasmine (same as JavaScript)
module TypeScriptData
  include CommentStripper

  def src_file_filter
    lambda do |f|
      path = if f.class == Hash then f[:path] else f end
      path.match?(/\.(ts|tsx)$/) && !test_file_filter.call(f)
    end
  end

  def test_file_filter
    lambda do |f|
      path = if f.class == Hash then f[:path] else f end
      path.match?(/\.(ts|tsx)$/) &&
        (path.match?(/\.(test|spec)\.(ts|tsx)$/) ||
         path.match?(/tests?\//i) ||
         path.match?(/__tests__\/.*\.(ts|tsx)$/i))
    end
  end

  def test_case_filter
    lambda do |l|
      # Jest/Mocha/Jasmine: it/test/describe
      !l.match(/^\s*(it|test|describe)\s*\(/).nil?
    end
  end

  def assertion_filter
    lambda do |l|
      # Jest: expect(...)
      # Chai: assert.*, should.*, expect(...)
      !l.match(/expect\s*\(/).nil? ||
        !l.match(/assert\s*\./).nil? ||
        !l.match(/should\s*\./).nil?
    end
  end

  def strip_comments(buff)
    strip_c_style_comments(buff)
  end
end