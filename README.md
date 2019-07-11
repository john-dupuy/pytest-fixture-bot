pytest-fixture-evaluator-bot
==================

Small script to annoy people when they've modified fixtures and post a comment to check tests which use those fixtures.

To run this using docker you can do:
```
docker build -t fixture-evaluator-bot .
docker run -v /path/to/conf:/usr/src/app/conf fixture-evaluator-bot:latest
```
Where `/path/to/conf` is the path to the yaml configuration directory
