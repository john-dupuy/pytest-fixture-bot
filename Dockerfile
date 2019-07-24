FROM ruby:2.6

# throw errors if Gemfile has been modified since Gemfile.lock
RUN bundle config --global frozen 1

WORKDIR /usr/src/app

# install ruby dependencies and Python
COPY Gemfile Gemfile.lock ./
RUN gem install bundler && bundle install && apt-get update && apt-get install python3 python3-pip git -y && apt-get clean
# install python dependencies (integration_tests and its venv)
RUN git clone https://github.com/ManageIQ/integration_tests.git && cd integration_tests && pip3 --no-cache-dir install -r requirements/frozen.py3.txt

COPY fixture_bot.rb /usr/src/app/fixture_bot.rb

# run the ruby script
CMD /usr/src/app/fixture_bot.rb