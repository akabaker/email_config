USE mail;
INSERT INTO domains (domain) VALUES ('example.com');
INSERT INTO users (email, password) VALUES ('test@example.com', ENCRYPT('password'));
quit
