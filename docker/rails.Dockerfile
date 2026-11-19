FROM ruby:3.4-slim

# mysql2 builds its native extension against the client headers; git backs --since.
RUN apt-get update && apt-get install -y --no-install-recommends \
      build-essential default-libmysqlclient-dev git && \
    rm -rf /var/lib/apt/lists/*

RUN gem install --no-document \
      "rails:8.1.4.1" "sqlite3:2.10.2" "mysql2:0.5.7" "minitest:6.1.0"

ENV LANG=C.UTF-8 LC_ALL=C.UTF-8
WORKDIR /app
CMD ["ruby", "-v"]
