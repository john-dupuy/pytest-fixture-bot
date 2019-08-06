FROM ruby:2.6

# throw errors if Gemfile has been modified since Gemfile.lock
RUN bundle config --global frozen 1

# allow this container to run as non-root user
RUN adduser --disabled-password fixture-bot && adduser fixture-bot root
WORKDIR /home/fixture-bot
RUN chmod -R 775 /home/fixture-bot && chown -R fixture-bot:root /home/fixture-bot

# install ruby dependencies
COPY Gemfile Gemfile.lock ./
RUN gem install bundler && bundle install 

COPY fixture_bot.rb /home/fixture-bot/fixture_bot.rb

# Specify user
USER 1000

# run the ruby script
CMD /home/fixture-bot/fixture_bot.rb
