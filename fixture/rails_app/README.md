A minimal Rails application used by `test/e2e/rails_test.rb`,
`test/e2e/mysql_test.rb`, and `docs/rails.md`. It boots through
`config/environment`, eager loads, and has one pure model and one Active Record
model so the campaign exercises both a plain unit test and a database test.

SQLite is the default. `SABAKU_DB=mysql` boots the test environment on MySQL,
with `sabaku_mysql.rb` as the `--setup` file.

The gems are not vendored. Build the image the checks use with
`docker build -f docker/rails.Dockerfile -t sabaku:rails .`, then run
`bin/check-rails` for the SQLite and MySQL campaigns.
