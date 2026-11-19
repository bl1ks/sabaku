FROM ruby:3.4-slim

# git backs --since (git diff) and the diff test; nothing else needs it.
RUN apt-get update && apt-get install -y --no-install-recommends git && \
    rm -rf /var/lib/apt/lists/*

RUN gem install --no-document minitest benchmark-ips && \
    ruby -e 'require "minitest"; puts "preloaded minitest=#{Minitest::VERSION}"'

ENV LANG=C.UTF-8 LC_ALL=C.UTF-8
WORKDIR /app
CMD ["ruby", "-v"]
