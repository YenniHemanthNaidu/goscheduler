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

// PauseSchedule pauses a recurring schedule by updating its status to PAUSED
// This will also delete all future executions of the schedule
func (s *Service) PauseSchedule(w http.ResponseWriter, r *http.Request) {
	var errs []string

	vars := mux.Vars(r)
	scheduleID := vars["scheduleId"]
	uuid, err := gocql.ParseUUID(scheduleID)

	if err != nil {
		glog.Errorf("Cannot parse UUID from %s", scheduleID)

		errs = append(errs, err.Error())
		s.recordRequestStatus(constants.PauseSchedule, constants.Fail)
		er.Handle(w, r, er.NewError(er.InvalidDataCode, errors.New(strings.Join(errs, ","))))
		return
	}

	// First, get the schedule to ensure it exists and is recurring
	schedule, err := s.ScheduleDao.GetSchedule(uuid)
	if err != nil {
		if err == gocql.ErrNotFound {
			glog.Infof("No schedule with id :  %s found", uuid)
			s.recordRequestStatus(constants.PauseSchedule, constants.Fail)

			errs = append(errs, fmt.Sprintf("Schedule with id: %s not found", uuid))
			er.Handle(w, r, er.NewError(er.DataNotFound, errors.New(strings.Join(errs, ","))))
		} else {
			glog.Errorf("Error fetching schedule with id %s", uuid)
			s.recordRequestStatus(constants.PauseSchedule, constants.Fail)

			errs = append(errs, err.Error())
			er.Handle(w, r, er.NewError(er.DataPersistenceFailure, errors.New(strings.Join(errs, ","))))
		}
		return
	}

	// Check if the schedule is recurring
	if !schedule.IsRecurring() {
		s.recordRequestStatus(constants.PauseSchedule, constants.Fail)
		glog.Info("schedule with id %s is not recurring", uuid)
		errs = append(errs, fmt.Sprintf("Schedule with id: %s is not a recurring schedule", uuid))
		er.Handle(w, r, er.NewError(er.UnprocessableEntity, errors.New(strings.Join(errs, ","))))
		return
	}

	// Check if already paused
	if schedule.Status == store.Paused {
		s.recordRequestStatus(constants.PauseSchedule, constants.Success)

		glog.Info("Schedule with id %s is already paused", uuid)
		status := Status{
			StatusCode:    constants.SuccessCode200,
			StatusMessage: "Schedule already paused",
			StatusType:    constants.Success,
			TotalCount:    1,
		}
		data := ScheduleData{
			Schedule: schedule,
		}
		_ = json.NewEncoder(w).Encode(
			ScheduleResponse{
				Status: status,
				Data:   data,
			})
		return
	}

	// Update the schedule status to PAUSED
	updatedSchedule, err := s.ScheduleDao.UpdateRecurringScheduleStatus(schedule, store.Paused)
	if err != nil {
		glog.Errorf("Error pausing schedule with id %s: %v", uuid, err)
		s.recordRequestStatus(constants.PauseSchedule, constants.Fail)
		errs = append(errs, err.Error())
		er.Handle(w, r, er.NewError(er.DataPersistenceFailure, errors.New(strings.Join(errs, ","))))
		return
	}

	glog.V(constants.INFO).Infof("Schedule with id %s paused", uuid.String())
	s.recordRequestStatus(constants.PauseSchedule, constants.Success)

	status := Status{
		StatusCode:    constants.SuccessCode200,
		StatusMessage: "Schedule paused successfully",
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
