# std/http

The `http` standard library module provides utilities for making HTTP requests. It acts as a wrapper around the language's native HTTP capabilities.

## Types

### `Response`

Represents an HTTP response returned by the `fetch` and `request` functions.

```ts
pub @struct Response {
    status: int;
    body: string;
}
```

* **`status`**: The HTTP status code of the response (e.g., `200` for OK, `404` for Not Found).
* **`body`**: The raw string content of the response body.

## Functions

### `fetch`

```ts
pub @func fetch(url)
```

Performs a simple HTTP GET request to the specified `url`. 

* **Parameters**: 
  * `url`: A string representing the endpoint to fetch.
* **Returns**: A `Response` object containing the HTTP status and body.
* **Throws**: An error named `"HttpError"` if the request fails (e.g., network error, DNS resolution failure). The error payload contains the underlying native error name.

#### Example

```ts
const http = import("std/http");
const print = import("std/print");

const res = http.fetch("https://example.com");
print.print_ln(res.status); // 200
print.print_ln(res.body);   // The HTML content of example.com
```

### `request`

```ts
pub @func request(url, method, body)
```

Performs an HTTP request to the specified `url` with a custom `method` and an optional `body`.

* **Parameters**: 
  * `url`: A string representing the endpoint.
  * `method`: A string specifying the HTTP method to use (e.g., `"GET"`, `"POST"`, `"PUT"`, `"PATCH"`, `"DELETE"`). Note that the method name must be uppercase. If an unknown method is provided, it defaults to GET.
  * `body`: The string payload to send with the request. Pass `null` if no body is needed.
* **Returns**: A `Response` object containing the HTTP status and body.
* **Throws**: An error named `"HttpError"` if the request fails.

#### Example

```ts
const http = import("std/http");
const print = import("std/print");

// Make a POST request with a JSON body
const json_body = "{\"key\": \"value\"}";
const res = http.request("https://httpbin.org/post", "POST", json_body);

print.print_ln(res.status); // 200
print.print_ln(res.body);   // The JSON response from httpbin
```

## Error Handling

Both `fetch` and `request` can throw an error if there is a problem reaching the server or executing the request. The error name will be `"HttpError"`, and the error payload will contain a string detailing the underlying native error reason (e.g., `UnknownHostName`, `ConnectionRefused`).
