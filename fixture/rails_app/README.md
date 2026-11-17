A minimal Rails application used by `test/e2e/rails_test.rb` and
`docs/rails.md`. It boots through `config/environment`, eager loads, and has one
pure model and one Active Record model so the campaign exercises both a plain
unit test and a transactional fixture.

The gems are not vendored. Run it in the `ruby-mutation:rails` image, which has
Rails and sqlite3 installed, or point `BUNDLE_PATH` at your own bundle.
