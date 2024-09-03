%flink.ssql(type=update)
INSERT INTO total_distance SELECT 'leaderboard:total_distance' as zset_key, SUM(distance), player_id
FROM TABLE(
        TUMBLE(TABLE `player_data`, DESCRIPTOR(event_time), INTERVAL '30' SECOND))
GROUP BY window_start, window_end, player_id