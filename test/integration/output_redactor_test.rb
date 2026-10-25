require 'test_helper'
class OutputRedactorTest < ActiveSupport::TestCase
  test 'nested bare credentials split across chunks never appear in output' do
    redactor=Pool::OutputRedactor.new([JSON.generate(environment:{API_KEY:'synthetic-key-123456789'})]) # gitleaks:allow -- synthetic redaction fixture
    first=redactor.push('stdout',"working\nsynthetic-key-")
    assert_equal "working\n",first
    second=redactor.push('stdout',"123456789\n")
    assert_equal "[REDACTED]\n",second
    assert_equal '',redactor.push('stdout','',final:true)
  end
  test 'multiline credential prefix is retained across line boundaries' do
    redactor=Pool::OutputRedactor.new(["private\ncredential"])
    assert_equal '',redactor.push('stderr',"private\n")
    assert_equal "[REDACTED]\n",redactor.push('stderr',"credential\n")
  end
end
