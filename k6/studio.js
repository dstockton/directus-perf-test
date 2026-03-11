import http from 'k6/http';
import { check, group } from 'k6';

const BASE_URL = __ENV.BASE_URL || 'http://directus:8055';
const ADMIN_EMAIL = __ENV.ADMIN_EMAIL || 'admin@example.com';
const ADMIN_PASSWORD = __ENV.ADMIN_PASSWORD || 'AdminPassword123';

export const options = {
  vus: parseInt(__ENV.K6_VUS || '10'),
  duration: __ENV.K6_DURATION || '5s',
  summaryTrendStats: ['avg', 'p(95)', 'p(99)'],
};

export function setup() {
  const res = http.post(
    `${BASE_URL}/auth/login`,
    JSON.stringify({ email: ADMIN_EMAIL, password: ADMIN_PASSWORD }),
    { headers: { 'Content-Type': 'application/json' } }
  );
  const token = JSON.parse(res.body).data.access_token;
  return { token };
}

export default function (data) {
  const headers = {
    Authorization: `Bearer ${data.token}`,
  };

  group('studio_load', () => {
    check(http.get(`${BASE_URL}/settings`, { headers }), {
      'settings 200': (r) => r.status === 200,
    });
    check(http.get(`${BASE_URL}/collections`, { headers }), {
      'collections 200': (r) => r.status === 200,
    });
    check(http.get(`${BASE_URL}/fields`, { headers }), {
      'fields 200': (r) => r.status === 200,
    });
    check(
      http.get(`${BASE_URL}/items/articles?fields=id,title,status,author.name&limit=50`, {
        headers,
      }),
      {
        'articles 200': (r) => r.status === 200,
      }
    );
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
