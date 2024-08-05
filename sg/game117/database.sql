CREATE TABLE IF NOT EXISTS reservations (
	id SERIAL PRIMARY KEY,
	reservationid VARCHAR(255),
	startdatetime VARCHAR(255), 
	enddatetime VARCHAR(255),
	pickuplocation VARCHAR(255), 
	reservationtitle VARCHAR(255),
	accesscode VARCHAR(255)
);

CREATE TABLE IF Not EXISTS website (
    id SERIAL PRIMARY KEY,
    website_version VARCHAR(255),
    title VARCHAR(255),
    menu_main_title VARCHAR(255),
    menu_main_link VARCHAR(255),
    menu_one_title VARCHAR(255),
    menu_one_link VARCHAR(255),
    menu_two_title VARCHAR(255),
    menu_two_link VARCHAR(255),
    menu_three_title VARCHAR(255),
    menu_three_link VARCHAR(255),
    body_header_title VARCHAR(255),
    lookup_message VARCHAR(255),
    details_message VARCHAR(255),
    deployments int DEFAULT 0
);

INSERT INTO website (title, website_version, 
                    menu_main_title, menu_main_link,
                    menu_one_title, menu_one_link,
                    menu_two_title, menu_two_link,
                    menu_three_title, menu_three_link,
                    body_header_title, lookup_message,
                    details_message
                    ) VALUES ('Unicorn.Rentals', 'v11012',
                              'Unicorn Rentals Reservations', '#',
                              'Home', '#',
                              'About', '#about',
                              'Contact', '#contact',
                              'Unicorn Reservations Lookup',
                              'Please Enter Your Reservation ID:',
                              'Reservation Information:');
                              
INSERT INTO reservations (reservationid,startdatetime,enddatetime,pickuplocation,reservationtitle,accesscode) VALUES ('5000000','2015-02-25','2015-02-25','Voluptatem consequatur accusantium sit perferendis aut.','Miss Alba Schiller','NSWMCHZZsDmTLLGkmFiFupdLG');
INSERT INTO reservations (reservationid,startdatetime,enddatetime,pickuplocation,reservationtitle,accesscode) VALUES ('5000001','1989-05-24','1989-05-24','Voluptatem accusantium perferendis sit consequatur aut.','Miss Anahi Keeling','xOZCydFLJYowNZuSYSxzIMcge');
INSERT INTO reservations (reservationid,startdatetime,enddatetime,pickuplocation,reservationtitle,accesscode) VALUES ('5000002','2014-04-01','2014-04-01','Sit consequatur perferendis aut voluptatem accusantium.','Mrs. Juliet Bartell','OLllfeNYTbdwOLfaEsfOGAKEu');
INSERT INTO reservations (reservationid,startdatetime,enddatetime,pickuplocation,reservationtitle,accesscode) VALUES ('5000003','2003-08-09','2003-08-09','Sit voluptatem accusantium consequatur perferendis aut.','Mrs. Evie Grady','HTYSgkLshuOEVXyHBcxSjBHRx');
INSERT INTO reservations (reservationid,startdatetime,enddatetime,pickuplocation,reservationtitle,accesscode) VALUES ('5000004','1998-01-26','1998-01-26','Voluptatem sit consequatur accusantium aut perferendis.','Queen Rosanna Leuschke','OycaeeycGSliiAhpMvNqUiZge');
INSERT INTO reservations (reservationid,startdatetime,enddatetime,pickuplocation,reservationtitle,accesscode) VALUES ('5000005','1989-12-15','1989-12-15','Voluptatem consequatur perferendis sit aut accusantium.','Prof. Lelia Reinger','vMpFodWfRojDLYkzlXZygqxHN');
INSERT INTO reservations (reservationid,startdatetime,enddatetime,pickuplocation,reservationtitle,accesscode) VALUES ('5000006','1998-01-08','1998-01-08','Consequatur perferendis aut accusantium voluptatem sit.','Ms. Celia Homenick','TWiMMLkdCqOOMkqRrdYUwryjx');
INSERT INTO reservations (reservationid,startdatetime,enddatetime,pickuplocation,reservationtitle,accesscode) VALUES ('5000007','2004-12-27','2004-12-27','Accusantium perferendis voluptatem sit consequatur aut.','Miss Ernestina Gaylord','MTJghjNTSSjnmpHFVDVcxWtRu');
INSERT INTO reservations (reservationid,startdatetime,enddatetime,pickuplocation,reservationtitle,accesscode) VALUES ('5000008','2017-11-04','2017-11-04','Accusantium voluptatem perferendis sit aut consequatur.','Queen Evie Willms','yhTMOvRrawkMkXIMYQfownLSH');
INSERT INTO reservations (reservationid,startdatetime,enddatetime,pickuplocation,reservationtitle,accesscode) VALUES ('5000009','1975-07-07','1975-07-07','Perferendis sit accusantium consequatur aut voluptatem.','Princess Dejah Ullrich','XjCOBKWgkxqlRmUvLqJtAAdrm');
INSERT INTO reservations (reservationid,startdatetime,enddatetime,pickuplocation,reservationtitle,accesscode) VALUES ('5000010','2001-11-29','2001-11-29','Aut perferendis accusantium voluptatem consequatur sit.','Dr. Christina Kovacek','SenLFVkCRWmOsyQiSgaCeOvfw');
INSERT INTO reservations (reservationid,startdatetime,enddatetime,pickuplocation,reservationtitle,accesscode) VALUES ('5000011','2016-07-18','2016-07-18','Voluptatem sit perferendis accusantium consequatur aut.','Miss Vida Collier','CZWVyzxEZAEUaLlObJzMkWRUz');
INSERT INTO reservations (reservationid,startdatetime,enddatetime,pickuplocation,reservationtitle,accesscode) VALUES ('5000012','1978-11-30','1978-11-30','Perferendis aut sit consequatur accusantium voluptatem.','Ms. Anna Braun','QPKcuIyyVKDBuVfeJbWGxMJYO');
INSERT INTO reservations (reservationid,startdatetime,enddatetime,pickuplocation,reservationtitle,accesscode) VALUES ('5000013','1985-07-12','1985-07-12','Accusantium voluptatem consequatur perferendis sit aut.','Queen Aurore Quitzon','LhOsGrpevBYgNfkTLxHVfTjug');
INSERT INTO reservations (reservationid,startdatetime,enddatetime,pickuplocation,reservationtitle,accesscode) VALUES ('5000014','1991-01-14','1991-01-14','Perferendis consequatur accusantium aut sit voluptatem.','Ms. Raina Marquardt','KPvvoNWHhdzpRPgbokCDhVewt');
INSERT INTO reservations (reservationid,startdatetime,enddatetime,pickuplocation,reservationtitle,accesscode) VALUES ('5000015','2015-11-22','2015-11-22','Perferendis aut voluptatem sit consequatur accusantium.','Ms. Brittany Klein','NvokYQZumbRmLfMyiozkxFIzy');
INSERT INTO reservations (reservationid,startdatetime,enddatetime,pickuplocation,reservationtitle,accesscode) VALUES ('5000016','1987-06-06','1987-06-06','Accusantium consequatur voluptatem aut perferendis sit.','Miss Taryn Luettgen','vQgmcyrdbvwBwtExDfAdkNucm');
INSERT INTO reservations (reservationid,startdatetime,enddatetime,pickuplocation,reservationtitle,accesscode) VALUES ('5000017','2000-05-25','2000-05-25','Voluptatem sit accusantium aut consequatur perferendis.','Mrs. Naomie Rohan','UQsBAepKUrJGHwcfjDCWTEjnZ');
INSERT INTO reservations (reservationid,startdatetime,enddatetime,pickuplocation,reservationtitle,accesscode) VALUES ('5000018','1985-08-29','1985-08-29','Sit aut accusantium voluptatem perferendis consequatur.','Miss Odessa Lehner','FPCpRFknJflOtKQaudCKzBiSP');
INSERT INTO reservations (reservationid,startdatetime,enddatetime,pickuplocation,reservationtitle,accesscode) VALUES ('5000019','1976-06-20','1976-06-20','Aut voluptatem sit accusantium perferendis consequatur.','Princess Ashley Cummerata','MDAwqLYYAJDhWcNOirNhjnWWy');
INSERT INTO reservations (reservationid,startdatetime,enddatetime,pickuplocation,reservationtitle,accesscode) VALUES ('5000020','1974-05-06','1974-05-06','Voluptatem accusantium consequatur sit perferendis aut.','Miss Marisa Feest','VQAhWvbxPqRkcSduLnMaZrNMR');
INSERT INTO reservations (reservationid,startdatetime,enddatetime,pickuplocation,reservationtitle,accesscode) VALUES ('5000021','1978-08-24','1978-08-24','Sit perferendis voluptatem accusantium consequatur aut.','Lady Suzanne Crist','TZCqvKBicnlOSxuZCJqTvOhty');
INSERT INTO reservations (reservationid,startdatetime,enddatetime,pickuplocation,reservationtitle,accesscode) VALUES ('5000022','1982-07-01','1982-07-01','Voluptatem accusantium perferendis consequatur aut sit.','Queen Odessa Davis','oHXnKvTJuyszqeDIDpxyrrXgG');
INSERT INTO reservations (reservationid,startdatetime,enddatetime,pickuplocation,reservationtitle,accesscode) VALUES ('5000023','2003-06-02','2003-06-02','Consequatur perferendis sit aut voluptatem accusantium.','Princess Serena Lemke','UYTKQrkqQDpXNqzUiiLkWBnVG');
INSERT INTO reservations (reservationid,startdatetime,enddatetime,pickuplocation,reservationtitle,accesscode) VALUES ('5000024','1974-05-07','1974-05-07','Voluptatem perferendis consequatur aut accusantium sit.','Dr. Kayla Shields','blmFVRsKGndHnLYfFltWYiPxf');
INSERT INTO reservations (reservationid,startdatetime,enddatetime,pickuplocation,reservationtitle,accesscode) VALUES ('5000025','2017-01-26','2017-01-26','Voluptatem perferendis sit consequatur aut accusantium.','Prof. Guadalupe Streich','PJSwZHfWJYUTZZBsCqCQfIDfy');
INSERT INTO reservations (reservationid,startdatetime,enddatetime,pickuplocation,reservationtitle,accesscode) VALUES ('5000026','1982-08-06','1982-08-06','Voluptatem aut accusantium sit perferendis consequatur.','Miss Karli McDermott','kXRAoPPvYDQTIiMNDaarZDhkz');
INSERT INTO reservations (reservationid,startdatetime,enddatetime,pickuplocation,reservationtitle,accesscode) VALUES ('5000027','2015-12-28','2015-12-28','Accusantium consequatur perferendis aut sit voluptatem.','Queen Lilian Dicki','XDmDfwrWqMrkCrkSVtcxSMhTo');
INSERT INTO reservations (reservationid,startdatetime,enddatetime,pickuplocation,reservationtitle,accesscode) VALUES ('5000028','2004-06-26','2004-06-26','Aut voluptatem accusantium sit perferendis consequatur.','Dr. Sister Mueller','EAZHtVqMpZHOFgCPEyxSrJsKT');
INSERT INTO reservations (reservationid,startdatetime,enddatetime,pickuplocation,reservationtitle,accesscode) VALUES ('5000029','1986-12-26','1986-12-26','Perferendis voluptatem consequatur aut sit accusantium.','Miss Delores Waters','FbxdDztWwLnlpgcLjQPwjSAag');