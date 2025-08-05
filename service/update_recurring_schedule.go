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

// validateImmutableFields ensures that immutable fields (appId, scheduleId, partitionId)
// are not being modified in the update request
func (s *Service) validateImmutableFields(inputSchedule, existing store.Schedule) error {
	var errs []string

	// Verify that appId is not being modified (only if provided in inputSchedule)
	if inputSchedule.AppId != "" && inputSchedule.AppId != existing.AppId {
		glog.Infof("Cannot modify appId for schedule with id %s", existing.ScheduleId)
		errs = append(errs, "Cannot modify appId for an existing schedule")
	}

	// Verify that scheduleId is not being modified (only if provided in inputSchedule)
	if !util.IsZeroUUID(inputSchedule.ScheduleId) && inputSchedule.ScheduleId != existing.ScheduleId {
		glog.Infof("Cannot modify scheduleId for schedule with id %s", existing.ScheduleId)
		errs = append(errs, "Cannot modify scheduleId for an existing schedule")
	}

	// Verify that partitionId is not being modified (only if provided in inputSchedule)
	if inputSchedule.PartitionId != existing.PartitionId {
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
	var inputSchedule store.Schedule

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

	err = json.Unmarshal(b, &inputSchedule) // inputSchedule is store.Schedule
	if err != nil {
		s.recordRequestStatus(constants.UpdateRecurringSchedule, constants.Fail)
		er.Handle(w, r, er.NewError(er.UnmarshalErrorCode, err))
		return
	}

	// First, get the schedule to ensure it exists and is recurring
	existingSchedule, err := s.ScheduleDao.GetSchedule(uuid)
	if err != nil {
		if err == gocql.ErrNotFound {
			glog.Infof("No existing schedule with id :  %s found", uuid)
			s.recordRequestStatus(constants.UpdateRecurringSchedule, constants.Fail)
			errs = append(errs, fmt.Sprintf("Schedule with id: %s not found", uuid))
			er.Handle(w, r, er.NewError(er.DataNotFound, errors.New(strings.Join(errs, ","))))
		} else {
			glog.Errorf("Error fetching existing schedule with id %s", uuid)
			s.recordRequestStatus(constants.UpdateRecurringSchedule, constants.Fail)
			errs = append(errs, err.Error())
			er.Handle(w, r, er.NewError(er.DataPersistenceFailure, errors.New(strings.Join(errs, ","))))
		}
		return
	}

	// Check if the existingSchedule is recurring
	if !existingSchedule.IsRecurring() {
		s.recordRequestStatus(constants.UpdateRecurringSchedule, constants.Fail)
		glog.Infof("existing schedule with id %s is not recurring", uuid)
		errs = append(errs, fmt.Sprintf("Schedule with id: %s is not a recurring schedule", uuid))
		er.Handle(w, r, er.NewError(er.UnprocessableEntity, errors.New(strings.Join(errs, ","))))
		return
	}

	// Validate immutable fields
	if err := s.validateImmutableFields(inputSchedule, existingSchedule); err != nil {
		s.recordRequestStatus(constants.UpdateRecurringSchedule, constants.Fail)
		er.Handle(w, r, er.NewError(er.InvalidDataCode, err))
		return
	}

	// Get the app for validation
	app, err := s.getApp(existingSchedule.AppId)
	if err != nil {
		glog.Errorf("Error fetching app %s: %v", existingSchedule.AppId, err)
		s.recordRequestStatus(constants.UpdateRecurringSchedule, constants.Fail)
		er.Handle(w, r, err.(er.AppError))
		return
	}

	// Update allowed fields
	if inputSchedule.CronExpression != "" {
		existingSchedule.CronExpression = inputSchedule.CronExpression
	}
	if inputSchedule.Payload != "" {
		existingSchedule.Payload = inputSchedule.Payload
	}
	if inputSchedule.CallbackRaw != nil {
		existingSchedule.CallbackRaw = inputSchedule.CallbackRaw
		// Create Callback from CallbackRaw
		callback, err := store.CreateCallbackFromRawMessage(inputSchedule.CallbackRaw)
		if err != nil {
			glog.Errorf("Error creating callback from raw message: %v", err)
			s.recordRequestStatus(constants.UpdateRecurringSchedule, constants.Fail)
			errs = append(errs, err.Error())
			er.Handle(w, r, er.NewError(er.InvalidDataCode, errors.New(strings.Join(errs, ","))))
			return
		}
		existingSchedule.Callback = callback
	}

	// Validate the updated existingSchedule
	validationErrs := existingSchedule.ValidateSchedule(app, s.Config.AppLevelConfiguration)
	if len(validationErrs) > 0 {
		glog.Errorf("UpdateRecurringSchedule: Validation errors: %v", validationErrs)
		s.recordRequestStatus(constants.UpdateRecurringSchedule, constants.Fail)
		er.Handle(w, r, er.NewError(er.UnprocessableEntity, errors.New(strings.Join(validationErrs, ","))))
		return
	}

	// Update the existingSchedule
	updatedSchedule, err := s.ScheduleDao.UpdateRecurringSchedule(existingSchedule)
	if err != nil {
		glog.Errorf("Error updating recurring existingSchedule with id %s: %v", uuid, err)
		s.recordRequestStatus(constants.UpdateRecurringSchedule, constants.Fail)
		errs = append(errs, err.Error())
		er.Handle(w, r, er.NewError(er.DataPersistenceFailure, errors.New(strings.Join(errs, ","))))
		return
	}

	glog.V(constants.INFO).Infof("Recurring existingSchedule with id %s updated", uuid.String())
	s.recordRequestStatus(constants.UpdateRecurringSchedule, constants.Success)

	status := Status{
		StatusCode:    constants.SuccessCode200,
		StatusMessage: "Recurring existingSchedule updated successfully",
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
