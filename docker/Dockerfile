FROM ruby:3.4-slim

RUN gem install --no-document rspec minitest benchmark-ips && \
    ruby -e 'require "minitest"; require "rspec"; puts "preloaded minitest=#{Minitest::VERSION} rspec=#{RSpec::Version::STRING}"'

ENV LANG=C.UTF-8 LC_ALL=C.UTF-8
WORKDIR /app
CMD ["ruby", "-v"]
