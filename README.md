pytest-fixture-bot
==================

Small script to annoy people when they've modified fixtures and post a comment to check tests which use those fixtures.

To run this using docker you can do:
```
docker build -t pytest-fixture-bot .
docker run -v /path/to/conf:/home/fixture-bot/conf pytest-fixture-bot:latest
```
Where `/path/to/conf` is the (local) path to the yaml configuration directory
