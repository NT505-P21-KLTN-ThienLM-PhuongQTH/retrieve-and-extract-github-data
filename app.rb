#!/usr/bin/env ruby
require 'sinatra'
require_relative 'app/config/environment'

# Cấu hình Sinatra
set :port, 4567
set :bind, '0.0.0.0' # Cho phép truy cập từ ngoài nếu cần

# Route cơ bản để kiểm tra server
get '/' do
  'GHTorrent Backend is running!'
end