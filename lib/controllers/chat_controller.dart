import 'dart:developer';

import 'package:firebase_database/firebase_database.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:http/http.dart' as http;

import '../api_integration/authentication_APIServices/login_api_service.dart';
import '../api_integration/create_Group_APIService/create_group_model_repository/model_and_fetchGroups.dart';
import '../constants/ApiEndPoint.dart';
import '../constants/chat_constant.dart';
import '../constants/fcm.dart';
import '../constants/firebase_utils.dart';
import '../models/message.dart';

class ChatController extends GetxController {
  Future<void> clearMessageCounter(String groupId, String userId) async {
    try {
      await chatGroupRef
          .child(groupId)
          .child('messageCounters')
          .child(userId)
          .set(0);

      log("Unread message counter for user $userId in group $groupId cleared.");
    } catch (error) {
      log("Error clearing message counter: $error");
    }
  }

  RxList<Message> messages = RxList([]);

  // TextEditingController messageController = TextEditingController();
  RxString image = "".obs;
  RxString messageTyping = "".obs;
  RxString messageImageUrl = "".obs;
  ScrollController scrollController = ScrollController();
  RxBool uploadingLoading = false.obs;
  RxInt remainingTime = 0.obs;
  RxBool canSendMessage = false.obs;

  // DateTime? lastMessageTime;
  List<Message> getMyMessages() {
    return messages.value
        .where((message) => message.senderId == FirebaseUtils.myId)
        .toList();
  }

  void scrollToBottom() {
    scrollController.animateTo(
      scrollController.position.maxScrollExtent,
      duration: Duration(milliseconds: 2),
      curve: Curves.fastOutSlowIn,
    );
  }

  void checkMessageSendingEligibility(Groups group, lastMessageTime) {
    if (lastMessageTime == null) {
      log("Time Sensitive time null $lastMessageTime");
      canSendMessage.value = true;
      remainingTime.value = group.timeSensitive;
    } else {
      log("Time Sensitive time not null $lastMessageTime");

      int remainingMinutes = getRemainingTime(group, lastMessageTime);
      log("again $remainingMinutes");
      log(remainingMinutes.toString());
      if (remainingMinutes == 0) {
        log("Time Sensitive Send $lastMessageTime");

        canSendMessage.value = true;
        remainingTime.value = group.timeSensitive;
        log("Remaining time send ${remainingTime.value.toString()}");
        update();
      } else {
        log("Time Sensitive time Not send$lastMessageTime");

        canSendMessage.value = false;
        remainingTime.value = remainingMinutes;
        log("Remaining time  not send ${remainingTime.value.toString()}");

        update();
      }
    }
    update();
  }

  Future<void> sendMessage({
    required Groups group,
    required String message,
    required List<String?> tokens,
    required MessageType messageType,
    VoiceMessage? voiceMessage,
    AudioMessage? audioMessage,
    VideoMessage? videoMessage,
    FileMessage? fileMessage,
    ImageMessage? imageMessage,
    List<Map<String, String>>? mentions,
  }) async {
    List<String> tokensList =
        tokens.where((token) => token != null).cast<String>().toList();
    log("Mention List$mentions");
    log("Tokens List$tokensList");
    int id = DateTime.now().millisecondsSinceEpoch;
    Message messageModel = Message(
      id: id.toString(),
      senderId: FirebaseUtils.myId,
      senderName: FirebaseUtils.myName,
      senderProfileImage: FirebaseUtils.myImage,
      content: message,
      type: messageType,
      reactions: {},
      status: "sent",
      timestamp: DateTime.now().millisecondsSinceEpoch,
      voiceMessage: messageType == MessageType.voice ? voiceMessage : null,
      audioMessage: messageType == MessageType.audio ? audioMessage : null,
      imageMessage: messageType == MessageType.image ? imageMessage : null,
      videoMessage: messageType == MessageType.video ? videoMessage : null,
      fileMessage: messageType == MessageType.file ? fileMessage : null,
    );

    try {
      Map<String, dynamic> messageData = messageModel.toJson();
      await chatGroupRef
          .child(group.id.toString())
          .child('messages')
          .child(messageModel.id)
          .set(messageData);
      log("Message sent successfully.");
      await addGemGroup();

      DateTime lastMessageTime = DateTime.now();
      var adminMember =
          group.members.where((element) => element.isAdmin == 1).toList();
      bool isCurrentUserAdmin = adminMember
          .any((element) => element.userId.toString() == FirebaseUtils.myId);
      log("Admin ${isCurrentUserAdmin.toString()}");
      log("Time ${group.timeSensitive.toString()}");
      if (group.timeSensitive != 0 && isCurrentUserAdmin == false) {
        log("Time sensitivity ${isCurrentUserAdmin}");
        checkMessageSendingEligibility(group, lastMessageTime);
      }
      for (var member in group.members) {
        if (member.userId.toString() != FirebaseUtils.myId) {
          log(member.userId.toString());
          await chatGroupRef
              .child(group.id.toString())
              .child('messageCounters')
              .child(member.userId.toString())
              .runTransaction((Object? counter) {
            if (counter == null) {
              return Transaction.success(1);
            } else {
              int currentValue = counter as int;
              return Transaction.success(currentValue + 1);
            }
          });
        }
      }

      // Update remaining time and send  notifications
      updateRemainingTimeAndSendNotification(tokensList, messageModel, group);
      scrollToBottom();
    } catch (error) {
      log("Error sending message: $error");
    }
  }

  void updateRemainingTimeAndSendNotification(
      List<String> tokensList, Message messageModel, Groups group) {
    if (tokensList.isNotEmpty) {
      String notificationMessage = "";
      switch (messageModel.type) {
        case MessageType.text:
          notificationMessage = messageModel.content;
          break;
        case MessageType.voice:
          notificationMessage = "Sent a voice message";
          break;
        case MessageType.audio:
          notificationMessage = "Sent an audio message";
          break;
        case MessageType.image:
          notificationMessage = "Sent an image";
          break;
        case MessageType.video:
          notificationMessage = "Sent a video";
          break;
        case MessageType.file:
          notificationMessage = "Sent a file";
          break;
      }
      FCM.sendMessageMulti(group.title, notificationMessage, tokensList);
    }
  }

  int getRemainingTime(Groups group, DateTime? lastMessageTime) {
    if (lastMessageTime == null) {
      return 0;
    }
    Duration difference = DateTime.now().difference(lastMessageTime);
    int minutesPassed = difference.inSeconds;
    log("minutesPassed$minutesPassed");
    int remainingMinutes = group.timeSensitive - minutesPassed;
    log("remainingMinutes$remainingMinutes");

    // 5 minutes cooldown period
    return remainingMinutes <= 0 ? 0 : remainingMinutes;
  }

  static Future<void> addGemGroup() async {
    String? token = await LoginAPIService.getToken();
    int userId = int.tryParse(FirebaseUtils.myId) ?? 0;
    log(userId.toString());

    final response = await http.post(
      Uri.parse('${AppEndPoint.baseUrl}/add-gem-group'),
      headers: {
        'Authorization': 'Bearer $token',
      },
      body: {'user_id': FirebaseUtils.myId},
    );
    log("Response ${response.body}");

    if (response.statusCode == 200) {
    } else {
      throw Exception('Failed to add gem to group');
    }
  }

  Future<void> updateTimeSensitive(int groupId, int timeSensitive) async {
    try {
      String? token = await LoginAPIService.getToken();

      final response = await http.post(
        Uri.parse('${AppEndPoint.baseUrl}/update-group-time-sensitivity'),
        headers: {
          'Authorization': 'Bearer $token',
        },
        body: {
          'group_id': groupId.toString(),
          'time_sensitive': timeSensitive.toString()
        },
      );
      log(response.body);
      if (response.statusCode == 200) {
        log("Time-sensitive property updated successfully.");
        Get.snackbar("Success", "Time-sensitive property updated successfully.",
            snackPosition: SnackPosition.BOTTOM,
            backgroundColor: Colors.green,
            colorText: Colors.white);
      } else {
        log("Failed to update time-sensitive property.");
      }
    } catch (e) {
      log("Error updating time-sensitive property: $e");
    } finally {}
  }
}