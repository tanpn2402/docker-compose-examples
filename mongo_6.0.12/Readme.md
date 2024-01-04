1. Restore
image = mongo:6.0.12-rc1 (use with mongo-express)

```sh
docker exec -it mongodb bash
mongorestore -u root -p 123456 /home/wtradeadmin
```

2. mongo-express
Enter http://localhost:8081 and enter admin/123456 to access mongodb administrator UI.

3. create new user
```sh
$ mongosh -u root -p
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
