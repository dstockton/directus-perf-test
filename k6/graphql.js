import http from 'k6/http';
import { check } from 'k6';

const BASE_URL = __ENV.BASE_URL || 'http://directus:8055';

export const options = {
  vus: parseInt(__ENV.K6_VUS || '10'),
  duration: __ENV.K6_DURATION || '5s',
  summaryTrendStats: ['avg', 'p(95)', 'p(99)'],
};

const QUERY = JSON.stringify({
  query: `{
    articles(limit: 25, sort: ["-publish_date"]) {
      id
      title
      body
      status
      publish_date
      category {
        id
        name
      }
      author {
        id
        name
      }
    }
  }`,
});

export default function () {
  const res = http.post(`${BASE_URL}/graphql`, QUERY, {
    headers: { 'Content-Type': 'application/json' },
  });
  check(res, {
    'status 200': (r) => r.status === 200,
  });
}

export function handleSummary(data) {
  return {
    stdout: JSON.stringify({
      p99: data.metrics.http_req_duration.values['p(99)'],
      p95: data.metrics.http_req_duration.values['p(95)'],
      avg: data.metrics.http_req_duration.values.avg,
      reqs: data.metrics.http_reqs.values.count,
      fails: data.metrics.http_req_failed.values.passes,
    }),
  };
}
