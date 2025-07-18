// Copyright (c) 2023 Myntra Designs Private Limited.
//
// Permission is hereby granted, free of charge, to any person obtaining a copy of
// this software and associated documentation files (the "Software"), to deal in
// the Software without restriction, including without limitation the rights to
// use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of
// the Software, and to permit persons to whom the Software is furnished to do so,
// subject to the following conditions:
//
// The above copyright notice and this permission notice shall be included in all
// copies or substantial portions of the Software.
//
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
// IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS
// FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR
// COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER
// IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN
// CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.

package service

import (
	"net/http"
	"net/http/httptest"
	"testing"

	"github.com/gocql/gocql"
	"github.com/gorilla/mux"
	"github.com/myntra/goscheduler/dao"
	"github.com/myntra/goscheduler/store"
)

// Custom mock implementation for pause tests
type MockScheduleDaoForPause struct {
	dao.DummyScheduleDaoImpl
}

// UpdateRecurringScheduleStatusCallCount tracks the number of calls for testing
var UpdateRecurringScheduleStatusCallCount int

// LastUpdateRecurringScheduleStatusArgs stores the last arguments for testing
var LastUpdateRecurringScheduleStatusArgs struct {
	Schedule store.Schedule
	Status   store.Status
}

func (m *MockScheduleDaoForPause) GetSchedule(uuid gocql.UUID) (store.Schedule, error) {
	switch uuid.String() {
	case "00000000-0000-0000-0000-000000000000":
		// Non-existent schedule
		return store.Schedule{}, gocql.ErrNotFound

	case "11111111-1111-1111-1111-111111111111":
		// Non-recurring schedule
		return store.Schedule{
			ScheduleId:     uuid,
			AppId:          "testApp",
			CronExpression: "", // Non-recurring by having empty cron expression
		}, nil

	case "22222222-2222-2222-2222-222222222222":
		// Already paused recurring schedule
		return store.Schedule{
			ScheduleId:     uuid,
			AppId:          "testApp",
			CronExpression: "0 0 * * *", // Recurring
			Status:         store.Paused,
		}, nil

	case "33333333-3333-3333-3333-333333333333":
		// DB error on update
		return store.Schedule{
			ScheduleId:     uuid,
			AppId:          "testDbError",
			CronExpression: "0 0 * * *", // Recurring
			Status:         store.Scheduled,
		}, nil

	case "44444444-4444-4444-4444-444444444444":
		// Partial failure
		return store.Schedule{
			ScheduleId:     uuid,
			AppId:          "testPartialFailure",
			CronExpression: "0 0 * * *", // Recurring
			Status:         store.Scheduled,
		}, nil

	case "66666666-6666-6666-6666-666666666666":
		// Recurring but currently not in SCHEDULED state (e.g., DELETED)
		return store.Schedule{
			ScheduleId:     uuid,
			AppId:          "testNotScheduled",
			CronExpression: "0 0 * * *", // Recurring
			Status:         store.Deleted,
		}, nil

	default:
		// Default is a valid recurring schedule
		return store.Schedule{
			ScheduleId:     uuid,
			AppId:          "testApp",
			CronExpression: "0 0 * * *", // Recurring
			Status:         store.Scheduled,
		}, nil
	}
}

func (m *MockScheduleDaoForPause) UpdateRecurringScheduleStatus(schedule store.Schedule, status store.Status) (store.Schedule, error) {
	// Track calls for testing
	UpdateRecurringScheduleStatusCallCount++
	LastUpdateRecurringScheduleStatusArgs.Schedule = schedule
	LastUpdateRecurringScheduleStatusArgs.Status = status

	switch schedule.AppId {
	case "testDbError":
		return schedule, gocql.ErrNotFound
	case "testPartialFailure":
		return schedule, gocql.ErrTimeoutNoResponse
	default:
		schedule.Status = status
		return schedule, nil
	}
}

// Add a function to get a properly mocked service handler for pause tests
func setupMocksForPauseTests() *Service {
	// Setup basic service structure
	sh := setupMocks()

	sh.ScheduleDao = &MockScheduleDaoForPause{}

	// Reset test tracking counters
	UpdateRecurringScheduleStatusCallCount = 0

	return sh
}

func TestService_PauseSchedule(t *testing.T) {
	service := setupMocksForPauseTests()

	tests := []struct {
		name               string
		scheduleID         string
		wantStatus         int
		description        string
		shouldUpdateStatus bool         // Whether UpdateRecurringScheduleStatus should be called
		expectedNewStatus  store.Status // Expected status to be set
	}{
		{
			name:               "InvalidUUID",
			scheduleID:         "invalid-uuid",
			wantStatus:         http.StatusBadRequest,
			description:        "Should return 400 for invalid UUID",
			shouldUpdateStatus: false,
		},
		{
			name:               "NonExistentSchedule",
			scheduleID:         "00000000-0000-0000-0000-000000000000",
			wantStatus:         http.StatusNotFound,
			description:        "Should return 404 when schedule does not exist",
			shouldUpdateStatus: false,
		},
		{
			name:               "NonRecurringSchedule",
			scheduleID:         "11111111-1111-1111-1111-111111111111",
			wantStatus:         http.StatusUnprocessableEntity,
			description:        "Should return 422 when trying to pause a non-recurring schedule",
			shouldUpdateStatus: false,
		},
		{
			name:               "AlreadyPausedSchedule",
			scheduleID:         "22222222-2222-2222-2222-222222222222",
			wantStatus:         http.StatusOK,
			description:        "Should return 200 when schedule is already paused",
			shouldUpdateStatus: false, // No update needed if already paused
		},
		{
			name:               "DatabaseError",
			scheduleID:         "33333333-3333-3333-3333-333333333333",
			wantStatus:         http.StatusInternalServerError,
			description:        "Should return 500 when database operation fails",
			shouldUpdateStatus: true,
			expectedNewStatus:  store.Paused,
		},
		{
			name:               "PartialFailure",
			scheduleID:         "44444444-4444-4444-4444-444444444444",
			wantStatus:         http.StatusInternalServerError,
			description:        "Should return 500 when batch operation fails partially",
			shouldUpdateStatus: true,
			expectedNewStatus:  store.Paused,
		},
		{
			name:               "SuccessfulPause",
			scheduleID:         "55555555-5555-5555-5555-555555555555",
			wantStatus:         http.StatusOK,
			description:        "Should return 200 on successful pause operation",
			shouldUpdateStatus: true,
			expectedNewStatus:  store.Paused,
		},
		{
			name:               "NotScheduledStatus",
			scheduleID:         "66666666-6666-6666-6666-666666666666",
			wantStatus:         http.StatusUnprocessableEntity,
			description:        "Should return 422 when schedule is not in SCHEDULED state",
			shouldUpdateStatus: false,
		},
	}

	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			// Reset the call count for each test
			UpdateRecurringScheduleStatusCallCount = 0

			req, err := http.NewRequest("PUT", "/goscheduler/schedules/{scheduleId}/pause", nil)
			if err != nil {
				t.Fatal(err)
			}

			vars := map[string]string{
				"scheduleId": tc.scheduleID,
			}

			req = mux.SetURLVars(req, vars)
			rr := httptest.NewRecorder()
			handler := http.HandlerFunc(service.PauseSchedule)
			handler.ServeHTTP(rr, req)

			// Check status code
			if status := rr.Code; status != tc.wantStatus {
				t.Errorf("handler returned wrong status code: got %v want %v, description: %s",
					status, tc.wantStatus, tc.description)
			}

			// Verify if UpdateRecurringScheduleStatus was called as expected
			if tc.shouldUpdateStatus {
				if UpdateRecurringScheduleStatusCallCount == 0 {
					t.Errorf("expected UpdateRecurringScheduleStatus to be called but it wasn't")
				}

				// Verify the status was properly passed to update method
				if LastUpdateRecurringScheduleStatusArgs.Status != tc.expectedNewStatus {
					t.Errorf("wrong status passed to UpdateRecurringScheduleStatus: got %v want %v",
						LastUpdateRecurringScheduleStatusArgs.Status, tc.expectedNewStatus)
				}
			} else {
				if UpdateRecurringScheduleStatusCallCount > 0 {
					t.Errorf("expected UpdateRecurringScheduleStatus not to be called but it was called %d times",
						UpdateRecurringScheduleStatusCallCount)
				}
			}
		})
	}
}
