1. Restore
```sh
mongorestore -d wtradeadmin
```

2. create new user
```sh
$ mongo -u root -p
$ use dbname
$ db.createUser(
  {
    user: "user1",
    pwd:  passwordPrompt(),
    roles: [ { role: "readWrite", db: "dbname" } ]
  }
);
$ show users;
```