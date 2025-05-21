#!/usr/bin/env ruby
require 'sinatra'
require 'sinatra/cors'
require 'dotenv/load'
require_relative 'app/config/environment'

register Sinatra::Cors

# Load .env
Dotenv.load(File.join(__dir__, '.env'))

# Cấu hình CORS
set :allow_origin, "*"
set :allow_methods, 'GET,POST,OPTIONS'
set :allow_headers, 'X-Requested-With, X-HTTP-Method-Override, Content-Type, Cache-Control, Accept, if-modified-since'
set :expose_headers, 'location,link'
set :max_age, '1728000'
set :allow_credentials, false

# Cấu hình Sinatra
set :port, 4567
set :bind, '0.0.0.0'


# Route cơ bản để kiểm tra server
get '/' do
  'GHTorrent Backend is running!'
end