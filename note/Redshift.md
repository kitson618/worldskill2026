## Check error log

```docker
SELECT * FROM stl_load_errors;
```

## Import data from S3

```docker
COPY TABLE_NAME FROM 's3://games-easy-storage-redshift-{AccountId}-{Region}/high_diamond_ranked_10min.csv'
iam_role 'arn:aws:iam::{AccountId}:role/JamRedshiftRole'
CSV
IGNOREHEADER 1
DATEFORMAT 'auto';
```

```
COPY TABLE_NAME
FROM 'S3_URL'
IAM_ROLE 'IAM_ROLE'
FORMAT AS CSV
DELIMITER ','
NULL 'NaN'
IGNOREHEADER 1
TIMEFORMAT 'DD/MM/YYYY HH:MI:SS'
REGION AS 'us-east-1';
```

## Count unique

```docker
SELECT
    count(distinct user_id)
FROM
    "dev"."public"."game_attempts" ;
```


## Create Model
```
CREATE MODEL predict_web_attacks
  FROM
  (
      select
        COLUMUS
        from TABLE
          )
  TARGET label
  FUNCTION predict_web_attacks
  IAM_ROLE 'arn:aws:iam::AccountID:role/RedshiftClusterRole-AccountID-region'
  AUTO OFF
  MODEL_TYPE XGBOOST
  OBJECTIVE 'multi:softmax'
  PREPROCESSORS 'none'
  HYPERPARAMETERS DEFAULT EXCEPT ( NUM_CLASS '5' )
  SETTINGS (
   S3_BUCKET 'labstack-prewarm-XXXXXX-XXX-X-redshifts3bucket-XXXXXX',
   MAX_RUNTIME 1500
  )
  ;
```

## Create Table

```docker
CREATE TABLE game_attempts(
    user_id numeric(10, 0), -- User ID.  This is the key to match with other datasets.
    level_id numeric(5, 0), -- Game level ID
    f_success integer, -- Indicates whether user completed the level (1: completed, 0: fails).
    f_duration real, -- duration of the attempt.  Units in seconds
    f_reststep real, -- The ratio of the remaining steps to the limited steps.  Failure is 0.
    f_help integer, -- Whether extra help, such as props and hints, was used.  1- used, 0- not used
    game_time timestamp, -- Attempt timestamp
    bp_used boolean -- Whether bonus packages used or not.  true: used, false: not used.
)
```

```docker
create table players_training_data as    
select t.user_id, 
    count(level_id) no_of_levels_played, 
    max(level_id) max_level_played, 
    sum(f_success) success_attempts, 
    count(*) - sum(f_success) failed_attempts,
    sum(f_help) times_used_help, 
    count(*) - sum(f_help) times_not_used_help,
    sum(f_duration) total_play_duration,
    avg(f_reststep) ratio_to_finish,
    max(g.bp_used::int)::boolean bp_used,
    t.bp_category,    
    t.lost_label    
from game_attempts g, training_users t    
where g.user_id=t.user_id    
group by t.user_id, t.lost_label,t.bp_category;
```