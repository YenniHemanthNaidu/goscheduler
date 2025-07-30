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
	"encoding/json"
	"errors"
	"fmt"
	"io/ioutil"
	"net/http"
	"strings"

	"github.com/gocql/gocql"
	"github.com/golang/glog"
	"github.com/gorilla/mux"
	"github.com/myntra/goscheduler/constants"
	er "github.com/myntra/goscheduler/error"
	"github.com/myntra/goscheduler/store"
	"github.com/myntra/goscheduler/util"
)

// UpdatedScheduleResponse is the response structure for the updateRecurringSchedule endpoint
type UpdatedScheduleResponse struct {
	Status Status              `json:"status"`
	Data   UpdatedScheduleData `json:"data"`
}

// UpdatedScheduleData contains the updated schedule
type UpdatedScheduleData struct {
	Schedule store.Schedule `json:"schedule"`
}

// validateImmutableFields ensures that immutable fields (appId, scheduleId, partitionId)
// are not being modified in the update request
func (s *Service) validateImmutableFields(input, existing store.Schedule) error {
	var errs []string

	// Verify that appId is not being modified (only if provided in input)
	if input.AppId != "" && input.AppId != existing.AppId {
		glog.Infof("Cannot modify appId for schedule with id %s", existing.ScheduleId)
		errs = append(errs, "Cannot modify appId for an existing schedule")
	}

	// Verify that scheduleId is not being modified (only if provided in input)
	if !util.IsZeroUUID(input.ScheduleId) && input.ScheduleId != existing.ScheduleId {
		glog.Infof("Cannot modify scheduleId for schedule with id %s", existing.ScheduleId)
		errs = append(errs, "Cannot modify scheduleId for an existing schedule")
	}

	// Verify that partitionId is not being modified (only if provided in input)
	if input.PartitionId != 0 && input.PartitionId != existing.PartitionId {
		glog.Infof("Cannot modify partitionId for schedule with id %s", existing.ScheduleId)
		errs = append(errs, "Cannot modify partitionId for an existing schedule")
	}

	if len(errs) > 0 {
		return errors.New(strings.Join(errs, ","))
	}

	return nil
}

// UpdateRecurringSchedule updates the existing recurring schedule with new values
// It supports updating cron expression, payload, headers, callback_type, call_back_url
func (s *Service) UpdateRecurringSchedule(w http.ResponseWriter, r *http.Request) {
	var errs []string
	var input store.Schedule

	vars := mux.Vars(r)
	scheduleID := vars["scheduleId"]
	uuid, err := gocql.ParseUUID(scheduleID)

	if err != nil {
		glog.Errorf("Cannot parse UUID from %s", scheduleID)
		errs = append(errs, err.Error())
		s.recordRequestStatus(constants.UpdateRecurringSchedule, constants.Fail)
		er.Handle(w, r, er.NewError(er.InvalidDataCode, errors.New(strings.Join(errs, ","))))
		return
	}

	// Read and unmarshal the request body
	b, err := ioutil.ReadAll(r.Body)
	if err != nil {
		glog.Errorf("UpdateRecurringSchedule: Error reading request body: %v", err)
		s.recordRequestStatus(constants.UpdateRecurringSchedule, constants.Fail)
		er.Handle(w, r, er.NewError(er.UnmarshalErrorCode, err))
		return
	}

	err = json.Unmarshal(b, &input) // input is store.Schedule
	if err != nil {
		s.recordRequestStatus(constants.UpdateRecurringSchedule, constants.Fail)
		er.Handle(w, r, er.NewError(er.UnmarshalErrorCode, err))
		return
	}

	// First, get the schedule to ensure it exists and is recurring
	schedule, err := s.ScheduleDao.GetSchedule(uuid)
	if err != nil {
		if err == gocql.ErrNotFound {
			glog.Infof("No schedule with id :  %s found", uuid)
			s.recordRequestStatus(constants.UpdateRecurringSchedule, constants.Fail)
			errs = append(errs, fmt.Sprintf("Schedule with id: %s not found", uuid))
			er.Handle(w, r, er.NewError(er.DataNotFound, errors.New(strings.Join(errs, ","))))
		} else {
			glog.Errorf("Error fetching schedule with id %s", uuid)
			s.recordRequestStatus(constants.UpdateRecurringSchedule, constants.Fail)
			errs = append(errs, err.Error())
			er.Handle(w, r, er.NewError(er.DataPersistenceFailure, errors.New(strings.Join(errs, ","))))
		}
		return
	}

	// Check if the schedule is recurring
	if !schedule.IsRecurring() {
		s.recordRequestStatus(constants.UpdateRecurringSchedule, constants.Fail)
		glog.Infof("schedule with id %s is not recurring", uuid)
		errs = append(errs, fmt.Sprintf("Schedule with id: %s is not a recurring schedule", uuid))
		er.Handle(w, r, er.NewError(er.UnprocessableEntity, errors.New(strings.Join(errs, ","))))
		return
	}

	// Validate immutable fields
	if err := s.validateImmutableFields(input, schedule); err != nil {
		s.recordRequestStatus(constants.UpdateRecurringSchedule, constants.Fail)
		er.Handle(w, r, er.NewError(er.InvalidDataCode, err))
		return
	}

	// Get the app for validation
	app, err := s.getApp(schedule.AppId)
	if err != nil {
		glog.Errorf("Error fetching app %s: %v", schedule.AppId, err)
		s.recordRequestStatus(constants.UpdateRecurringSchedule, constants.Fail)
		er.Handle(w, r, err.(er.AppError))
		return
	}

	// Update allowed fields
	if input.CronExpression != "" {
		schedule.CronExpression = input.CronExpression
	}
	if input.Payload != "" {
		schedule.Payload = input.Payload
	}
	if input.CallbackRaw != nil {
		schedule.CallbackRaw = input.CallbackRaw
		// Create Callback from CallbackRaw
		callback, err := store.CreateCallbackFromRawMessage(input.CallbackRaw)
		if err != nil {
			glog.Errorf("Error creating callback from raw message: %v", err)
			s.recordRequestStatus(constants.UpdateRecurringSchedule, constants.Fail)
			errs = append(errs, err.Error())
			er.Handle(w, r, er.NewError(er.InvalidDataCode, errors.New(strings.Join(errs, ","))))
			return
		}
		schedule.Callback = callback
	}

	// Validate the updated schedule
	validationErrs := schedule.ValidateSchedule(app, s.Config.AppLevelConfiguration)
	if len(validationErrs) > 0 {
		glog.Errorf("UpdateRecurringSchedule: Validation errors: %v", validationErrs)
		s.recordRequestStatus(constants.UpdateRecurringSchedule, constants.Fail)
		er.Handle(w, r, er.NewError(er.UnprocessableEntity, errors.New(strings.Join(validationErrs, ","))))
		return
	}

	// Update the schedule
	updatedSchedule, err := s.ScheduleDao.UpdateRecurringSchedule(schedule)
	if err != nil {
		glog.Errorf("Error updating recurring schedule with id %s: %v", uuid, err)
		s.recordRequestStatus(constants.UpdateRecurringSchedule, constants.Fail)
		errs = append(errs, err.Error())
		er.Handle(w, r, er.NewError(er.DataPersistenceFailure, errors.New(strings.Join(errs, ","))))
		return
	}

	glog.V(constants.INFO).Infof("Recurring schedule with id %s updated", uuid.String())
	s.recordRequestStatus(constants.UpdateRecurringSchedule, constants.Success)

	status := Status{
		StatusCode:    constants.SuccessCode200,
		StatusMessage: "Recurring schedule updated successfully",
		StatusType:    constants.Success,
		TotalCount:    1,
	}

	data := UpdatedScheduleData{
		Schedule: updatedSchedule,
	}
	_ = json.NewEncoder(w).Encode(
		UpdatedScheduleResponse{
			Status: status,
			Data:   data,
		})
}
