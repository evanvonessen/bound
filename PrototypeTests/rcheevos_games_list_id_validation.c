#include <stdint.h>
#include <stdio.h>
#include <string.h>

#include "rc_api_info.h"
#include "rc_error.h"

static int validate_response(const char* json, int expected_result,
                             uint32_t expected_id, const char* expected_name) {
  rc_api_fetch_games_list_response_t response;
  int result;
  int failed = 0;

  memset(&response, 0, sizeof(response));
  result = rc_api_process_fetch_games_list_response(&response, json);
  if (result != expected_result) {
    fprintf(stderr, "Expected parse result %d, got %d for %s\n", expected_result, result, json);
    failed = 1;
  } else if (result == RC_OK) {
    if (response.num_entries != 1 || response.entries[0].id != expected_id ||
        strcmp(response.entries[0].name, expected_name) != 0) {
      fprintf(stderr, "Parsed game list entry did not match expected ID/name for %s\n", json);
      failed = 1;
    }
  }

  /* The API caller owns response cleanup after success and parse errors alike. */
  rc_api_destroy_fetch_games_list_response(&response);
  return failed;
}

int main(void) {
  int failures = 0;

  failures += validate_response(
      "{\"Success\":true,\"Response\":{\"1234\":\"Ordinary game\"}}",
      RC_OK, 1234, "Ordinary game");
  failures += validate_response(
      "{\"Success\":true,\"Response\":{\"4294967295\":\"Maximum ID\"}}",
      RC_OK, UINT32_MAX, "Maximum ID");
  failures += validate_response(
      "{\"Success\":true,\"Response\":{\"4294967296\":\"Overflow ID\"}}",
      RC_INVALID_JSON, 0, "");
  failures += validate_response(
      "{\"Success\":true,\"Response\":{\"12x\":\"Nonnumeric suffix\"}}",
      RC_INVALID_JSON, 0, "");
  failures += validate_response(
      "{\"Success\":true,\"Response\":{\"-1\":\"Negative ID\"}}",
      RC_INVALID_JSON, 0, "");
  failures += validate_response(
      "{\"Success\":true,\"Response\":{\"\":\"Empty ID\"}}",
      RC_INVALID_JSON, 0, "");

  if (failures) {
    fprintf(stderr, "%d rcheevos game-list ID checks failed\n", failures);
    return 1;
  }

  puts("rcheevos game-list ID checks passed");
  return 0;
}
