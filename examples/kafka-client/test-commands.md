# Testing access as fraud-analytics

Prereqs: platform is up, the `fraud-analytics` tenant is applied, `minikube tunnel`
is running, and the SASL/PLAIN password matches in both the virtual cluster
(`apps/fraud-analytics/kong/virtual-cluster.yaml`) and the client properties.

## List topics (should show only the two granted logical names)

```bash
kafka-topics.sh --bootstrap-server bootstrap.fraud-analytics.127-0-0-1.sslip.io:9092 \
  --command-config fraud-analytics-client.properties --list
```

## Consume

```bash
kafka-console-consumer.sh \
  --bootstrap-server bootstrap.fraud-analytics.127-0-0-1.sslip.io:9092 \
  --consumer.config fraud-analytics-client.properties \
  --topic clients.sentiment-signals.v1 --from-beginning
```

## Negative test — access a topic you were NOT granted

```bash
# advisor.daily-client-activity.v1 was not in the ACL -> expect authorization error
kafka-console-consumer.sh \
  --bootstrap-server bootstrap.fraud-analytics.127-0-0-1.sslip.io:9092 \
  --consumer.config fraud-analytics-client.properties \
  --topic advisor.daily-client-activity.v1 --from-beginning
```

Run **Add Topics to Application** in Backstage (adding that topic), merge the PR,
wait for Argo CD to sync, and the same command now succeeds — with no credential or
endpoint change.
