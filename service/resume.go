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
	"net/http"
	"strings"

	"github.com/gocql/gocql"
	"github.com/golang/glog"
	"github.com/gorilla/mux"
	"github.com/myntra/goscheduler/constants"
	er "github.com/myntra/goscheduler/error"
	"github.com/myntra/goscheduler/store"
)

// ResumeSchedule resumes a paused recurring schedule by updating its status to SCHEDULED
func (s *Service) ResumeSchedule(w http.ResponseWriter, r *http.Request) {
	var errs []string

	vars := mux.Vars(r)
	scheduleID := vars["scheduleId"]
	uuid, err := gocql.ParseUUID(scheduleID)

	if err != nil {
		glog.Errorf("Cannot parse UUID from %s", scheduleID)

		errs = append(errs, err.Error())
		s.recordRequestStatus(constants.ResumeSchedule, constants.Fail)
		er.Handle(w, r, er.NewError(er.InvalidDataCode, errors.New(strings.Join(errs, ","))))
		return
	}

	// First, get the schedule to ensure it exists and is recurring
	schedule, err := s.ScheduleDao.GetSchedule(uuid)
	if err != nil {
		if err == gocql.ErrNotFound {
			glog.Infof("No schedule with id %s found", uuid)
			s.recordRequestStatus(constants.ResumeSchedule, constants.Fail)

			errs = append(errs, fmt.Sprintf("Schedule with id: %s not found", uuid))
			er.Handle(w, r, er.NewError(er.DataNotFound, errors.New(strings.Join(errs, ","))))
		} else {
			glog.Errorf("Error fetching schedule with id %s", uuid)
			s.recordRequestStatus(constants.ResumeSchedule, constants.Fail)

			errs = append(errs, err.Error())
			er.Handle(w, r, er.NewError(er.DataPersistenceFailure, errors.New(strings.Join(errs, ","))))
		}
		return
	}

	// Check if the schedule is recurring
	if !schedule.IsRecurring() {
		glog.Info("schedule with id %s is not recurring", uuid)
		s.recordRequestStatus(constants.ResumeSchedule, constants.Fail)
		errs = append(errs, fmt.Sprintf("Schedule with id: %s is not a recurring schedule", uuid))
		er.Handle(w, r, er.NewError(er.UnprocessableEntity, errors.New(strings.Join(errs, ","))))
		return
	}

	// Check if not paused
	if schedule.Status != store.Paused {
		glog.Info("schedule with id %s is not paused", uuid)
		s.recordRequestStatus(constants.ResumeSchedule, constants.Fail)
		errs = append(errs, fmt.Sprintf("Schedule with id: %s is not paused", uuid))
		er.Handle(w, r, er.NewError(er.Conflict, errors.New(strings.Join(errs, ","))))
		return
	}

	// Update the schedule status to SCHEDULED
	updatedSchedule, err := s.ScheduleDao.UpdateRecurringScheduleStatus(schedule, store.Scheduled)
	if err != nil {
		glog.Errorf("Error resuming schedule with id %s: %v", uuid, err)
		s.recordRequestStatus(constants.ResumeSchedule, constants.Fail)
		errs = append(errs, err.Error())
		er.Handle(w, r, er.NewError(er.DataPersistenceFailure, errors.New(strings.Join(errs, ","))))
		return
	}

	glog.V(constants.INFO).Infof("Schedule with id %s resumed", uuid.String())
	s.recordRequestStatus(constants.ResumeSchedule, constants.Success)

	status := Status{
		StatusCode:    constants.SuccessCode200,
		StatusMessage: "Schedule resumed successfully",
		StatusType:    constants.Success,
		TotalCount:    1,
	}
	data := ScheduleData{
		Schedule: updatedSchedule,
	}
	_ = json.NewEncoder(w).Encode(
		ScheduleResponse{
			Status: status,
			Data:   data,
		})
}
