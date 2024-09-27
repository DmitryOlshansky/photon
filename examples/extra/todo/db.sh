#!/bin/sh
docker run -d -e POSTGRES_PASSWORD='12345678' -p 5432:5432 postgres 
