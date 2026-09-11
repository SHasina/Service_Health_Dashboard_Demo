# Mock Downstream Service

A single, minimal FastAPI service used to stand in for `user-service`, `order-service`, and
`payment-service` in local development, docker-compose, and the kind cluster. Behavior is
controlled entirely through environment variables so one image is reused three times instead of
maintaining three near-identical services.

| Variable            | Default        | Effect                                              |
|---------------------|----------------|------------------------------------------------------|
| `MOCK_NAME`          | `mock-service` | Name reported in the response body and error detail.|
| `MOCK_MODE`          | `healthy`      | `healthy` returns 200 immediately; `error` returns 500; `slow` sleeps past the backend's 5-second timeout before returning 200. |
| `MOCK_DELAY_SECONDS` | `8`            | Sleep duration used when `MOCK_MODE=slow`.           |

Endpoint: `GET /health`
