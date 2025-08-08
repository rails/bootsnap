# Contributing to Bootsnap

We love receiving pull requests!

## Standards

* PR should explain what the feature does, and why the change exists.
* PR should include any carrier specific documentation explaining how it works.
* Code _must_ be tested, including both unit and remote tests where applicable.
* Be consistent. Write clean code that follows [Ruby community standards](https://github.com/bbatsov/ruby-style-guide).
* Code should be generic and reusable.

If you're stuck, ask questions!

## How to contribute

1. Fork it ( https://github.com/rails/bootsnap/fork )
2. Create your feature branch (`git checkout -b my-new-feature`)
3. Commit your changes (`git commit -am 'Add some feature'`)
4. Push to the branch (`git push origin my-new-feature`)
5. Create a new Pull Request

## Running Tests on Windows

### Setup

1. Ensure you've installed Ruby and the MSYS2 devkit and have ran `ridk enable` in your shell. The `ridk enable` command adds make to the path so the compile rake task works.

1. Open your shell as Administrator (`Run as Administrator`), as the tests create and delete symlinks

### Running Tests

> ridk enable
> bundle install
> bundle exec rake
